import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../astronomy/celestial_directions.dart';
import '../geodesy.dart';
import 'appearance.dart';
import 'aerial_inputs.dart';
import 'precomputed_source.dart';
import 'lut_cache.dart';
import 'parameters.dart';
import 'star_catalog.dart';
import 'scene_wgsl.dart';

const atmosphere = ServiceKey<AtmosphereController>('geospatial.atmosphere');

/// Optional native sky, celestial bodies and depth-based aerial perspective.
/// Scene positions use metres. [worldToEcef] accepts a rigid local world frame;
/// identity means the scene already uses ECEF coordinates. One instance per view.
final class AtmospherePlugin extends ScenePlugin {
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
    this.source,
    AtmosphereParameters? parameters,
    AtmosphereAppearance? appearance,
    this.ellipsoid = Ellipsoid.wgs84,
    Mat4? worldToEcef,
    StarCatalog? stars,
    this.moonMap,
    this.correctAltitude = true,
    this.maxStarResolution = 1024,
  }) : parameters =
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
  String get id => 'atmosphere';
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
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) =>
      controller._frame(frame);
}

/// Date and appearance updates invalidate the view without regenerating LUTs.
/// Parameter updates are serialized with frame preparation and publish atomically.
final class AtmosphereController {
  final AtmospherePlugin _plugin;
  final PluginContext _context;
  final GpuScope _owner;
  late final AtmosphereLutCache _cache = AtmosphereLutCache(_owner);
  late DateTime _date = _plugin.date.toUtc();
  late AtmosphereAppearance _appearance = _plugin.appearance;
  late AtmosphereParameters _parameters = _plugin.parameters;
  PrecomputedAtmosphereSource? _source;
  _AtmosphereCandidate? _active;
  RetainedAerialInputs? _inputs;
  Future<void> _queue = Future.value();
  bool _closed = false;
  int _width = 1, _height = 1;
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

  Future<void> _serial(Future<void> Function() action) {
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
    bool stopped() => isClosed || (cancelled?.call() ?? false);
    final lease = await _cache.acquire(
      parameters: parameters,
      source: source,
      isCancelled: stopped,
    );
    final scope = _owner.createChild(label: 'atmosphere scene');
    _AtmosphereCandidate? candidate;
    try {
      candidate = await _AtmosphereCandidate.build(
        scope,
        lease,
        _plugin,
        width,
        height,
        inputs ?? _inputs?.value ?? AerialPerspectiveInputs(),
      );
      if (stopped()) throw StateError('Atmosphere update cancelled.');
      // The previous effect remains registered until the candidate is accepted.
      final previous = _active;
      if (previous == null) {
        candidate.registration = _context.scene.addEffect(
          candidate.effect,
          requiresTransparentBackground: true,
        );
      } else {
        previous.registration!.replace(candidate.effect);
        candidate.registration = previous.registration;
        previous.registration = null;
      }
      _active = candidate;
      _parameters = parameters;
      _source = source;
      if (previous != null) await previous.close();
    } catch (_) {
      if (!identical(_active, candidate)) {
        await scope.close();
        await lease.close();
      }
      rethrow;
    }
  }

  Future<void> _frame(FrameInfo frame) => _serial(() async {
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
    final active = _active!;
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
          _plugin.ellipsoid.surfaceNormal(surface) * _parameters.bottomRadius;
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
    final sunScale = _parameters.sunRadianceToLuminance.dot(
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
    final inputs = _inputs?.value;
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
      0,
      inputs?.normal == null ? 0 : inputs!.normalEncoding.index + 1.0,
      inputs?.lightingMask == null
          ? -1
          : inputs!.lightingMaskChannel.toDouble(),
      inputs?.overlay == null ? 0 : 1,
      inputs?.normalSpace == AerialNormalSpace.world ? 1 : 0,
      ...(_plugin.ellipsoid.reciprocalRadiiSquared * 1e6).storage,
      0,
      ...((corrected - ecef) * .001 * correction).storage,
      0,
      ...right.storage,
      0,
      ...up.storage,
      0,
    ]);
    await active.scope.resources.writeBuffer(active.uniform, data);
    await active.graph.execute();
  });
  Future<void> _close() async {
    _closed = true;
    _active?.registration?.dispose();
    await _queue;
    await _active?.close();
    await _inputs?.scope.close();
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
  EffectRegistration? registration;
  _AtmosphereCandidate(
    this.scope,
    this.lease,
    this.uniform,
    this.graph,
    this.effect,
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
  ) async {
    final resources = scope.resources;
    final uniform = await resources.createBuffer(
      BufferDescriptor(
        size: 464,
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
    for (final input in [inputs.normal, inputs.lightingMask, inputs.overlay]) {
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
    return _AtmosphereCandidate(scope, lease, uniform, graph, effect);
  }
}
