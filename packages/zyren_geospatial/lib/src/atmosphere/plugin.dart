import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../astronomy/celestial_directions.dart';
import '../geodesy.dart';
import 'appearance.dart';
import 'lunar_lighting.dart';
import 'aerial_inputs.dart';
import 'cloud_inputs.dart';
import 'precomputed_source.dart';
import 'lut_cache.dart';
import 'parameters.dart';
import 'star_catalog.dart';
import 'scene_wgsl.dart';

const atmosphere = ServiceKey<AtmosphereController>('geospatial.atmosphere');

/// Optional native sky, celestial bodies and depth-based aerial perspective.
/// Scene positions use metres. [worldToEcef] accepts a rigid local world frame;
/// identity means the scene already uses ECEF coordinates. One instance per view.
class AtmospherePlugin extends ScenePlugin {
  final String instanceId;
  final Set<String> additionalDependencies;
  final DateTime date;
  final AtmosphereParameters parameters;
  final PrecomputedAtmosphereSource? source;
  final AtmosphereAppearance appearance;
  final Ellipsoid ellipsoid;
  final Mat4 worldToEcef;
  final StarCatalog stars;
  final MoonMap? moonMap;
  final bool correctAltitude;
  final int maxStarResolution;
  AtmosphereController? _controller;
  AtmosphereController get controller =>
      _controller ?? (throw StateError('Atmosphere is not attached.'));
  AtmospherePlugin({
    required this.date,
    this.instanceId = 'atmosphere',
    Set<String> additionalDependencies = const {},
    this.source,
    AtmosphereParameters? parameters,
    AtmosphereAppearance? appearance,
    this.ellipsoid = Ellipsoid.wgs84,
    Mat4? worldToEcef,
    StarCatalog? stars,
    this.moonMap,
    this.correctAltitude = true,
    this.maxStarResolution = 1024,
  }) : additionalDependencies = Set.unmodifiable(additionalDependencies),
       parameters =
           parameters ?? source?.parameters ?? AtmosphereParameters.webgpu(),
       appearance = appearance ?? AtmosphereAppearance(),
       worldToEcef = worldToEcef ?? Mat4.identity(),
       stars = stars ?? StarCatalog.brightStars() {
    AstronomicalTime(date);
    if (source != null && this.parameters.key != source!.parameters.key) {
      throw ArgumentError(
        'Atmosphere parameters must match the imported tables.',
      );
    }
    if (maxStarResolution < 1 || maxStarResolution > 2048) {
      throw ArgumentError.value(maxStarResolution, 'maxStarResolution');
    }
    final m = this.worldToEcef.storage;
    final axes = [
      for (var i = 0; i < 3; i++) Vec3(m[i * 4], m[i * 4 + 1], m[i * 4 + 2]),
    ];
    if ([m[3], m[7], m[11], m[15] - 1].any((v) => v.abs() > 1e-12) ||
        axes.any((v) => (v.length - 1).abs() > 1e-8) ||
        axes[0].cross(axes[1]).distanceTo(axes[2]) > 1e-8) {
      throw ArgumentError(
        'Atmosphere worldToEcef must be a proper rigid transform in metres.',
      );
    }
  }
  @override
  String get id => instanceId;
  @override
  Set<String> get dependencies => additionalDependencies;
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.renderGraphs,
    RenderFeature.compute,
    RenderFeature.floatTextures,
    RenderFeature.volumeTextures,
    RenderFeature.shaderMaterials,
    RenderFeature.postprocessing,
    RenderFeature.hdr,
  };
  @override
  Future<void> attach(PluginContext context) async {
    final owner = context.createGpuScope(label: 'atmosphere');
    final control = _controller = AtmosphereController._(this, context, owner);
    context.scope.onClose(control._close);
    context.provide(atmosphere, control);
    if (source == null) {
      await control.setParameters(parameters);
    } else {
      await control.setSource(source!);
    }
    control._bindCandidate(control._active);
  }

  @override
  Future<void> afterRender(
    PluginContext context,
    FrameInfo info,
    FrameStats stats,
  ) => controller._presented(info, stats);

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) =>
      controller._frame(frame);
}

/// Date and appearance updates invalidate the view without regenerating LUTs.
/// Parameter updates allocate atomically. Scene bindings change during frame
/// preparation, while public settings describe the accepted request.
final class AtmosphereController {
  final AtmospherePlugin _plugin;
  final PluginContext _context;
  final GpuScope _owner;
  late final AtmosphereLutCache _cache = AtmosphereLutCache(_owner);
  late DateTime _date = _plugin.date.toUtc();
  late AtmosphereAppearance _appearance = _plugin.appearance;
  late AtmosphereParameters _parameters = _plugin.parameters;
  PrecomputedAtmosphereSource? _source;
  _AtmosphereCandidate? _active, _bound, _displayed;
  final _candidates = <_AtmosphereCandidate>{};
  FrameInfo? _submittedFrame;
  _AtmosphereCandidate? _submittedCandidate, _submittedDisplayed;
  RetainedAerialInputs? _inputs;
  RetainedAtmosphereCloudInputs? _cloudInputs;
  AtmosphereCloudRegistration? _cloudRegistration;
  final _preparedClouds = <PreparedAtmosphereCloudInputs>{};
  Future<void> _queue = Future.value();
  bool _closed = false;
  bool _enabled = true;
  bool get enabled => _enabled;
  set enabled(bool value) {
    _check();
    if (_enabled == value) return;
    _enabled = value;
    _context.invalidate();
  }

  int _width = 1, _height = 1;
  FrameInfo? _lastFrame;
  AtmosphereController._(this._plugin, this._context, this._owner);
  bool get isClosed => _closed || _owner.isClosed;
  AtmosphereParameters get parameters => _parameters;
  PrecomputedAtmosphereSource? get source => _source;
  Mat4 get worldToEcef => _plugin.worldToEcef;
  Ellipsoid get ellipsoid => _plugin.ellipsoid;
  bool get correctAltitude => _plugin.correctAltitude;

  /// Acquire the current tables for your own atmospheric lighting shader.
  /// Keep the lease until its material retires. A parameter edit leaves existing
  /// leases valid; acquire again when you want the new lighting parameters.
  Future<AtmosphereLutLease> acquireLighting({bool Function()? isCancelled}) {
    _check();
    return _cache.acquire(
      parameters: _parameters,
      source: _source,
      isCancelled: isCancelled,
    );
  }

  DateTime get date => _date;
  set date(DateTime value) {
    _check();
    AstronomicalTime(value);
    _date = value.toUtc();
    _context.invalidate();
  }

  AtmosphereAppearance get appearance => _appearance;
  set appearance(AtmosphereAppearance value) {
    _check();
    _appearance = value;
    _context.invalidate();
  }

  void _check() {
    if (isClosed) throw StateError('Atmosphere controller has closed.');
  }

  /// Publish screen maps together. An empty value clears all maps. Failure keeps
  /// the previous effect and retained inputs; caller scopes may close on success.
  Future<void> setAerialInputs(AerialPerspectiveInputs value) =>
      _serial(() async {
        final candidate = await RetainedAerialInputs.retain(_owner, value);
        try {
          await _replace(
            _parameters,
            _source,
            _width,
            _height,
            null,
            inputs: candidate.value,
          );
          final previous = _inputs;
          _inputs = candidate;
          await previous?.scope.close();
          _context.invalidate();
        } catch (_) {
          if (!identical(_inputs, candidate)) await candidate.scope.close();
          rethrow;
        }
      });

  /// Own cloud composition independently of caller normals, masks and overlays.
  /// Only one cloud producer may hold this registration at a time.
  Future<AtmosphereCloudRegistration> registerCloudInputs(
    AtmosphereCloudInputs inputs,
  ) => _serial(() async {
    if (_cloudRegistration != null) {
      throw StateError('Atmosphere already has a cloud producer.');
    }
    await _changeCloudInputs(inputs);
    return _cloudRegistration = AtmosphereCloudRegistration._(this);
  });

  Future<void> _changeCloudInputs(AtmosphereCloudInputs? inputs) async {
    final candidate = inputs == null
        ? null
        : await RetainedAtmosphereCloudInputs.retain(_owner, inputs);
    final previous = _cloudInputs;
    _cloudInputs = candidate;
    try {
      await _replace(_parameters, _source, _width, _height, null);
    } catch (_) {
      _cloudInputs = previous;
      await candidate?.scope.close();
      rethrow;
    }
    await previous?.scope.close();
    _context.invalidate();
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) {
      _check();
      return action();
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  /// Generate a new atmosphere and replace any imported source after success.
  Future<void> setParameters(
    AtmosphereParameters parameters, {
    bool Function()? isCancelled,
  }) => _serial(() async {
    await _replace(parameters, null, _width, _height, isCancelled);
    _parameters = parameters;
    _context.invalidate();
  });

  /// Load and publish a complete source set. Failure leaves the current view intact.
  Future<void> setSource(
    PrecomputedAtmosphereSource source, {
    bool Function()? isCancelled,
  }) => _serial(() async {
    await _replace(source.parameters, source, _width, _height, isCancelled);
    _context.invalidate();
  });
  Future<void> _replace(
    AtmosphereParameters parameters,
    PrecomputedAtmosphereSource? source,
    int width,
    int height,
    bool Function()? cancelled, {
    AerialPerspectiveInputs? inputs,
  }) async {
    final replacements =
        <PreparedAtmosphereCloudInputs, _AtmosphereCandidate>{};
    _AtmosphereCandidate? candidate;
    try {
      candidate = await _buildCandidate(
        parameters,
        source,
        width,
        height,
        cancelled,
        inputs ?? _inputs?.value ?? AerialPerspectiveInputs(),
        _cloudInputs?.value,
      );
      for (final prepared in _preparedClouds) {
        replacements[prepared] = await _buildCandidate(
          parameters,
          source,
          width,
          height,
          cancelled,
          inputs ?? _inputs?.value ?? AerialPerspectiveInputs(),
          prepared._inputs.value,
        );
      }
    } catch (_) {
      await candidate?.close();
      for (final value in replacements.values) {
        await value.close();
      }
      rethrow;
    }
    _acceptCandidate(candidate);
    _parameters = parameters;
    _source = source;
    final retired = <_AtmosphereCandidate>[];
    for (final entry in replacements.entries) {
      retired.add(entry.key._candidate);
      entry.key._candidate = entry.value;
    }
    await _retireCandidates();
    for (final value in retired) {
      await value.close();
    }
  }

  Future<_AtmosphereCandidate> _buildCandidate(
    AtmosphereParameters parameters,
    PrecomputedAtmosphereSource? source,
    int width,
    int height,
    bool Function()? cancelled,
    AerialPerspectiveInputs inputs,
    AtmosphereCloudInputs? clouds,
  ) async {
    bool stopped() => isClosed || (cancelled?.call() ?? false);
    final lease = await _cache.acquire(
      parameters: parameters,
      source: source,
      isCancelled: stopped,
    );
    GpuScope? scope;
    try {
      scope = _owner.createChild(label: 'atmosphere scene');
      final candidate = await _AtmosphereCandidate.build(
        scope,
        lease,
        _plugin,
        width,
        height,
        inputs,
        clouds,
      );
      if (_lastFrame != null) {
        await _writeFrame(candidate, _lastFrame!, width, height);
      }
      if (stopped()) throw StateError('Atmosphere update cancelled.');
      return candidate;
    } catch (_) {
      await scope?.close();
      await lease.close();
      rethrow;
    }
  }

  void _acceptCandidate(_AtmosphereCandidate candidate) {
    _active = candidate;
    _candidates.add(candidate);
  }

  void _bindCandidate(_AtmosphereCandidate? candidate) {
    if (identical(candidate, _bound)) return;
    final previous = _bound;
    if (candidate == null) {
      previous?.registration?.dispose();
      previous?.registration = null;
    } else if (previous?.registration == null) {
      candidate.registration = _context.scene.addEffect(
        candidate.effect,
        requiresTransparentBackground: true,
      );
    } else {
      previous!.registration!.replace(candidate.effect);
      candidate.registration = previous.registration;
      previous.registration = null;
    }
    _bound = candidate;
  }

  Future<void> _retireCandidates() async {
    final retained = {
      _active,
      _bound,
      _displayed,
      _submittedCandidate,
      _submittedDisplayed,
    };
    for (final candidate in _candidates.toList()) {
      if (!retained.contains(candidate)) {
        _candidates.remove(candidate);
        await candidate.close();
      }
    }
  }

  Future<void> _presented(FrameInfo frame, FrameStats stats) =>
      _serial(() async {
        if (!identical(frame, _submittedFrame)) {
          throw StateError(
            'Atmosphere receipt does not match its prepared frame.',
          );
        }
        _displayed = stats.admission?.candidateReady == false
            ? _submittedDisplayed
            : _submittedCandidate;
        _submittedFrame = null;
        _submittedCandidate = _submittedDisplayed = null;
        await _retireCandidates();
      });

  Future<void> _frame(FrameInfo frame) => _serial(() => _prepareFrame(frame));
  Future<void> _prepareFrame(FrameInfo frame) async {
    _submittedFrame = null;
    _submittedCandidate = _submittedDisplayed = null;
    final scale = math.min(
      1.0,
      _plugin.maxStarResolution / math.max(frame.width, frame.height),
    );
    final width = math.max(1, (frame.width * scale).round()),
        height = math.max(1, (frame.height * scale).round());
    if (width != _width || height != _height) {
      await _replace(_parameters, _source, width, height, null);
      _width = width;
      _height = height;
    }
    _bindCandidate(_enabled ? _active : null);
    final active = _bound;
    if (active != null) {
      await _writeFrame(active, frame, active.width, active.height);
    }
    final displayed = _displayed;
    if (displayed != null && !identical(displayed, active)) {
      await _writeFrame(displayed, frame, displayed.width, displayed.height);
    }
    _lastFrame = _submittedFrame = frame;
    _submittedCandidate = active;
    _submittedDisplayed = displayed;
    await _retireCandidates();
  }

  Future<void> _writeFrame(
    _AtmosphereCandidate active,
    FrameInfo frame,
    int width,
    int height,
  ) async {
    final parameters = active.lease.luts.parameters;
    final camera = _context.camera;
    final ecef = _point(_plugin.worldToEcef, camera.position);
    if (ecef.length < 1 || ecef.length > 1e12) {
      throw ArgumentError(
        'Atmosphere camera must be outside the ellipsoid centre and within 1e12 metres.',
      );
    }
    var corrected = ecef;
    if (_plugin.correctAltitude) {
      final surface = _plugin.ellipsoid.projectOnSurface(ecef);
      corrected =
          ecef -
          surface +
          _plugin.ellipsoid.surfaceNormal(surface) * parameters.bottomRadius;
    }
    final directions = CelestialDirections.at(_date, observerECEF: ecef);
    final worldInverse = _plugin.worldToEcef.inverted();
    final worldRotation = Mat4([
      ..._plugin.worldToEcef.storage.take(12),
      0,
      0,
      0,
      1,
    ]);
    final inverseRotation = Mat4([
      ...worldInverse.storage.take(12),
      0,
      0,
      0,
      1,
    ]);
    final a = _appearance;
    final sunScale = parameters.sunRadianceToLuminance.dot(
      const Vec3(.2126, .7152, .0722),
    );
    final forward = (camera.target - camera.position).normalized();
    final right = forward.cross(camera.up).normalized();
    final up = right.cross(forward);
    var correction = 0.0;
    if (a.correctGeometricError) {
      final height = math.max(0.0, _plugin.ellipsoid.fromEcef(ecef).height);
      final scale = camera is OrthographicCamera
          ? (2 * _plugin.ellipsoid.maximumRadius - camera.top - camera.bottom) /
                ((camera.top - camera.bottom) / camera.zoom)
          : camera is PerspectiveCamera
          ? _plugin.ellipsoid.maximumRadius *
                camera.zoom /
                (math.tan(camera.fieldOfView / 2) * math.max(height, 1e-9))
          : double.infinity;
      correction = ((scale - 41.5) / (13.8 - 41.5)).clamp(0, 1);
    }
    final inputs = active.inputs;
    final data = Float32List.fromList([
      ...(corrected * .001).storage,
      camera is OrthographicCamera ? 1 : 0,
      ...directions.sunECEF.storage,
      a.sunIntensity,
      ...directions.moonECEF.storage,
      a.moonIntensity,
      a.haze ? 1 : 0,
      a.ground ? 1 : 0,
      a.sky ? 1 : 0,
      a.moonAngularRadius,
      width.toDouble(),
      height.toDouble(),
      a.starPointSize,
      a.sky ? a.starIntensity / sunScale : 0,
      ...worldRotation.storage,
      ...(inverseRotation * directions.eciToEcef).storage,
      ...camera.viewProjection(frame.width / frame.height).storage,
      ...(directions.eciToEcef * directions.moonFixedToEci).storage,
      ...forward.storage,
      camera is OrthographicCamera ? camera.near : 0,
      a.transmittance ? 1 : 0,
      a.inscatter ? 1 : 0,
      a.sunLight ? 1 : 0,
      a.skyLight ? 1 : 0,
      a.albedoScale,
      a.reconstructNormal ? 1 : 0,
      correction,
      active.hasClouds ? 1 : 0,
      inputs.normal == null ? 0 : inputs.normalEncoding.index + 1.0,
      inputs.lightingMask == null ? -1 : inputs.lightingMaskChannel.toDouble(),
      inputs.overlay == null ? 0 : 1,
      inputs.normalSpace == AerialNormalSpace.world ? 1 : 0,
      ...(_plugin.ellipsoid.reciprocalRadiiSquared * 1e6).storage,
      0,
      ...((corrected - ecef) * .001 * correction).storage,
      0,
      ...right.storage,
      0,
      ...up.storage,
      0,
      lunarIrradianceScale(directions, a),
      a.nightLightIntensity,
      a.moonLight || a.nightLightIntensity > 0 ? 1 : 0,
      inputs.medium == null ? 0 : 1,
    ]);
    await active.scope.resources.writeBuffer(active.uniform, data);
    await active.graph.execute();
  }

  Future<void> _close() async {
    _closed = true;
    _bound?.registration?.dispose();
    await _queue;
    for (final candidate in _candidates) {
      await candidate.close();
    }
    _candidates.clear();
    for (final prepared in _preparedClouds.toList()) {
      await prepared._dispose();
    }
    await _inputs?.scope.close();
    await _cloudInputs?.scope.close();
    await _cache.close();
    await _owner.close();
  }
}

Vec3 _point(Mat4 matrix, Vec3 p) {
  final m = matrix.storage;
  return Vec3(
    m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
    m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
    m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14],
  );
}

final class _AtmosphereCandidate {
  final GpuScope scope;
  final AtmosphereLutLease lease;
  final GpuResource<Buffer> uniform;
  final CompiledGraph graph;
  final ScreenEffect effect;
  final AerialPerspectiveInputs inputs;
  final bool hasClouds;
  final int width, height;
  EffectRegistration? registration;
  _AtmosphereCandidate(
    this.scope,
    this.lease,
    this.uniform,
    this.graph,
    this.effect,
    this.inputs,
    this.hasClouds,
    this.width,
    this.height,
  );
  Future<void> close() async {
    registration?.dispose();
    try {
      await scope.close();
    } finally {
      await lease.close();
    }
  }

  static Future<_AtmosphereCandidate> build(
    GpuScope scope,
    AtmosphereLutLease lease,
    AtmospherePlugin plugin,
    int width,
    int height,
    AerialPerspectiveInputs inputs,
    AtmosphereCloudInputs? clouds,
  ) async {
    final resources = scope.resources;
    final uniform = await resources.createBuffer(
      BufferDescriptor(
        size: 480,
        usage: {BufferUsage.uniform, BufferUsage.copyDestination},
      ),
    );
    final catalogue = await resources.createBuffer(
      BufferDescriptor(
        size: plugin.stars.stars.length * 32,
        usage: {BufferUsage.storage, BufferUsage.copyDestination},
      ),
    );
    await resources.writeBuffer(
      catalogue,
      Float32List.fromList([
        for (final star in plugin.stars.stars) ...[
          ...star.directionECI.storage,
          star.magnitude,
          ...star.color.toList(),
          0,
        ],
      ]),
    );
    final target = await resources.createTexture(
      TextureDescriptor(
        width: width,
        height: height,
        format: TextureFormat.rgba16Float,
        usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
      ),
    );
    final moon = plugin.moonMap;
    final moonTexture = await resources.createTexture(
      TextureDescriptor(
        width: moon?.width ?? 1,
        height: moon?.height ?? 1,
        format: TextureFormat.rgba8UnormSrgb,
        usage: {TextureUsage.sampled, TextureUsage.copyDestination},
      ),
    );
    await resources.writeTexture(
      moonTexture,
      moon?.pixels ?? Uint8List.fromList([255, 255, 255, 255]),
    );
    final starProgram = await scope.shaders.compile(
      ShaderSource.wgsl(atmosphereSceneUniforms + atmosphereStarsWgsl),
    );
    final graph = await scope.graphs.compile(
      GraphDescription(
        inputs: [uniform, catalogue],
        passes: [
          RenderPassDescriptor(
            name: 'star catalogue',
            program: starProgram,
            color: ColorAttachment(target),
            blend: RenderBlend.additive,
            vertexCount: 6,
            instanceCount: plugin.stars.stars.length,
            bindings: ShaderBindings([
              BufferBinding.uniform(0, uniform, group: 2),
              BufferBinding.storageRead(1, catalogue, group: 2),
            ]),
            reads: [uniform, catalogue],
            writes: [target],
          ),
        ],
      ),
    );
    final library = lease.luts.shader();
    final placeholder = await resources.createTexture(
      TextureDescriptor(width: 1, height: 1, format: TextureFormat.rgba8Unorm),
    );
    await resources.writeTexture(placeholder, Uint8List(4));
    final maps = <GpuResource<Texture>>[];
    for (final input in [
      inputs.normal,
      inputs.lightingMask,
      inputs.overlay,
      clouds?.color,
      clouds?.depthVelocityShadow,
      clouds?.transmittance,
      inputs.medium?.transport,
    ]) {
      maps.add(input == null ? placeholder : await resources.retain(input));
    }
    final program = await scope.shaders.compile(
      ShaderSource.wgsl(
        PostProcessDescriptor.interfaceWgsl +
            library.source +
            atmosphereSceneUniforms +
            atmosphereCompositeWgsl,
      ),
    );
    final effect = await scope.materials.compileEffect(
      PostProcessDescriptor(
        program: program,
        bindings: ShaderBindings([
          ...library.bindings.entries,
          BufferBinding.uniform(0, uniform, group: 2),
          TextureBinding.sampled(1, target, group: 2),
          TextureBinding.sampled(2, moonTexture, group: 2),
          for (var i = 0; i < maps.length; i++)
            TextureBinding.sampled(i + 3, maps[i], group: 2),
        ]),
      ),
    );
    return _AtmosphereCandidate(
      scope,
      lease,
      uniform,
      graph,
      effect,
      inputs,
      clouds != null,
      width,
      height,
    );
  }
}

/// Exclusive cloud inputs. Replacement and close publish complete effects; failed
/// replacements leave the previous cloud maps installed. Close before retiring
/// your producer. The atmosphere keeps retained copies until replacement.
final class AtmosphereCloudRegistration {
  final AtmosphereController _controller;
  bool _closed = false;
  AtmosphereCloudRegistration._(this._controller);
  bool get isClosed => _closed || _controller.isClosed;

  /// Allocate a complete replacement without changing scene bindings. Publish
  /// it during your frame preparation, or close it when the request is abandoned.
  Future<PreparedAtmosphereCloudInputs> prepare(AtmosphereCloudInputs inputs) =>
      _controller._serial(() async {
        _check();
        final retained = await RetainedAtmosphereCloudInputs.retain(
          _controller._owner,
          inputs,
        );
        try {
          final candidate = await _controller._buildCandidate(
            _controller._parameters,
            _controller._source,
            _controller._width,
            _controller._height,
            null,
            _controller._inputs?.value ?? AerialPerspectiveInputs(),
            retained.value,
          );
          final prepared = PreparedAtmosphereCloudInputs._(
            this,
            retained,
            candidate,
          );
          _controller._preparedClouds.add(prepared);
          return prepared;
        } catch (_) {
          await retained.scope.close();
          rethrow;
        }
      });
  void _check() {
    if (isClosed || !identical(_controller._cloudRegistration, this)) {
      throw StateError('Atmosphere cloud registration has closed.');
    }
  }

  Future<void> replace(AtmosphereCloudInputs inputs) =>
      _controller._serial(() async {
        if (isClosed || !identical(_controller._cloudRegistration, this)) {
          throw StateError('Atmosphere cloud registration has closed.');
        }
        await _controller._changeCloudInputs(inputs);
      });
  Future<void> close() async {
    if (isClosed) {
      _closed = true;
      return;
    }
    await _controller._serial(() async {
      if (!identical(_controller._cloudRegistration, this)) {
        _closed = true;
        return;
      }
      await _controller._changeCloudInputs(null);
      for (final prepared in _controller._preparedClouds.toList()) {
        await prepared._dispose();
      }
      _controller._cloudRegistration = null;
      _closed = true;
    });
  }
}

/// A prepared cloud composition. Publish from an awaited beforeRender hook after
/// the atmosphere hook, passing that same frame. Publication consumes the token.
/// Preparation allocates GPU resources; publication only updates existing work.
final class PreparedAtmosphereCloudInputs {
  final AtmosphereCloudRegistration _registration;
  final RetainedAtmosphereCloudInputs _inputs;
  _AtmosphereCandidate _candidate;
  bool _finished = false;
  PreparedAtmosphereCloudInputs._(
    this._registration,
    this._inputs,
    this._candidate,
  );
  AtmosphereController get _controller => _registration._controller;
  bool get isClosed => _finished || _registration.isClosed;

  Future<void> publish(FrameInfo frame) => _controller._serial(() async {
    if (!_controller._context.isPreparingFrame(frame) ||
        !identical(frame, _controller._submittedFrame)) {
      throw StateError(
        'Publish cloud inputs during the same engine frame preparation.',
      );
    }
    _registration._check();
    if (_finished) {
      throw StateError('Prepared cloud inputs were already consumed.');
    }
    await _controller._writeFrame(
      _candidate,
      frame,
      _candidate.width,
      _candidate.height,
    );
    _controller._acceptCandidate(_candidate);
    _controller._bindCandidate(_controller._enabled ? _candidate : null);
    _controller._submittedCandidate = _controller._bound;
    final inputs = _controller._cloudInputs;
    _controller._cloudInputs = _inputs;
    _finished = true;
    _controller._preparedClouds.remove(this);
    await _controller._retireCandidates();
    await inputs?.scope.close();
    _controller._context.invalidate();
  });

  Future<void> close() async {
    if (isClosed) return;
    await _controller._serial(_dispose);
  }

  Future<void> _dispose() async {
    if (_finished) return;
    _finished = true;
    _controller._preparedClouds.remove(this);
    await _candidate.close();
    await _inputs.scope.close();
  }
}
