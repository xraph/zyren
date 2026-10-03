import 'package:zyren/zyren.dart';
import '../atmosphere/plugin.dart';
import '../atmosphere/lunar_lighting.dart';
import '../atmosphere/cloud_inputs.dart';
import '../atmosphere/lut_cache.dart';
import '../atmosphere/precomputed_source.dart';
import '../astronomy/celestial_directions.dart';
import 'appearance.dart';
import 'frame.dart';
import 'parameters.dart';
import 'quality.dart';
import 'textures.dart';
import 'shadow_pass.dart';
import 'media_wgsl.dart';
import 'sampling_wgsl.dart';
import 'shadow_wgsl.dart';
import 'render_wgsl.dart';
import 'history.dart';
import 'frame_budget.dart';
import 'temporal_pass.dart';
import 'temporal_wgsl.dart';
import 'blue_noise_wgsl.dart';
import 'texture_source.dart';

const clouds = ServiceKey<CloudController>('geospatial.clouds');

/// Native volumetric clouds over an AtmospherePlugin. Positions and layer heights
/// use metres. Set explicit target limits to fit clouds and other scene resources
/// within your device budget. Cloud maps are retained until replacement.
final class CloudPlugin extends ScenePlugin {
  final CloudParameters parameters;
  final CloudAppearance appearance;
  final CloudQualityPreset quality;
  final CloudTemporalSettings temporal;
  final CloudSceneFrameBudget? sceneFrameBudget;
  final bool animationEnabled;
  final CloudTextureSource? source;
  final CloudBlueNoiseSource? blueNoiseSource;
  final CloudTextures? textures;
  final CloudBlueNoise? blueNoise;
  final int maxResolution;
  final int maxPixels;
  final int? shadowMapSize;
  final bool shadowsEnabled;
  final CloudQualityPreset? shadowQuality;
  final double shadowFarScale;
  CloudController? _controller;
  CloudPlugin({
    CloudParameters? parameters,
    CloudAppearance? appearance,
    CloudTemporalSettings? temporal,
    this.quality = CloudQualityPreset.medium,
    this.sceneFrameBudget,
    this.animationEnabled = true,
    this.source,
    this.blueNoiseSource,
    this.textures,
    this.blueNoise,
    this.maxResolution = 384,
    this.maxPixels = 1048576,
    this.shadowMapSize,
    this.shadowsEnabled = true,
    this.shadowQuality,
    this.shadowFarScale = 1,
  }) : parameters = parameters ?? CloudParameters(),
       appearance = appearance ?? CloudAppearance(),
       temporal = temporal ?? CloudTemporalSettings() {
    if (textures != null && source != null ||
        blueNoise != null && blueNoiseSource != null) {
      throw ArgumentError(
        'Choose loaded cloud assets or their source for each input.',
      );
    }
    if (!shadowFarScale.isFinite || shadowFarScale <= 0 || shadowFarScale > 1) {
      throw ArgumentError.value(
        shadowFarScale,
        'shadowFarScale',
        'Must be in (0, 1].',
      );
    }
    RangeError.checkValueInInterval(maxResolution, 1, 4096, 'maxResolution');
    RangeError.checkValueInInterval(maxPixels, 1, 16777216, 'maxPixels');
    if (shadowMapSize != null) {
      RangeError.checkValueInInterval(shadowMapSize!, 1, 1024, 'shadowMapSize');
    }
  }
  CloudController get controller =>
      _controller ?? (throw StateError('Clouds are not attached.'));
  @override
  String get id => 'clouds';
  @override
  Set<String> get dependencies => {'atmosphere'};
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.compute,
    RenderFeature.renderGraphs,
    RenderFeature.volumeTextures,
    RenderFeature.floatTextures,
    RenderFeature.postprocessing,
    RenderFeature.hdr,
  };
  @override
  Future<void> attach(PluginContext context) async {
    final control = _controller = CloudController._(
      this,
      context,
      context.createGpuScope(label: 'clouds'),
      context.service(atmosphere),
    );
    context.scope.onClose(control._close);
    context.provide(clouds, control);
    await control._initialize();
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) =>
      controller._frame(frame);
  @override
  Future<void> afterRender(
    PluginContext context,
    FrameInfo info,
    FrameStats stats,
  ) => controller._presented(info.number, stats);
}

final class CloudController {
  final CloudPlugin _plugin;
  final PluginContext _context;
  final GpuScope _owner;
  final AtmosphereController _atmosphere;
  late CloudParameters _parameters = _plugin.parameters;
  late CloudAppearance _appearance = _plugin.appearance;
  late CloudQualityPreset _quality = _plugin.quality;
  late int _maxResolution = _plugin.maxResolution;
  late int _maxPixels = _plugin.maxPixels;
  late int? _shadowMapSize = _plugin.shadowMapSize;
  late bool _shadowsEnabled = _plugin.shadowsEnabled;
  late CloudQualityPreset? _shadowQuality = _plugin.shadowQuality;
  late CloudTemporalSettings _temporal = _plugin.temporal;
  late bool _animationEnabled = _plugin.animationEnabled;
  late CloudSceneFrameController? _frameBudget =
      _plugin.sceneFrameBudget == null
      ? null
      : CloudSceneFrameController(_plugin.sceneFrameBudget!);
  Duration _animationElapsed = Duration.zero;
  bool _skipAnimationDelta = false;
  final _initialHistory = CloudHistory();
  CloudHistory get _history => _active?.history ?? _initialHistory;
  int _revision = 0;
  _CloudCandidate? _displayed, _bound;
  _CloudSubmission? _submission;
  final _candidates = <_CloudCandidate>{};
  CloudTextureSet? _textures;
  CloudBlueNoise? _blueNoise;
  final _sourceCancellation = _CloudSourceCancellation();
  _CloudCandidate? _active;
  EffectRegistration? _producer, _resolve, _publish;
  AtmosphereCloudRegistration? _composition;
  Registration? _demand;
  Future<void> _queue = Future.value();
  bool _closed = false;
  int _width = 1, _height = 1;
  int _viewportWidth = 1, _viewportHeight = 1;

  CloudController._(this._plugin, this._context, this._owner, this._atmosphere);
  bool get isClosed => _closed || _owner.isClosed;
  CloudParameters get parameters => _parameters;
  set parameters(CloudParameters value) {
    _check();
    _parameters = value;
    _revision++;
    _history.invalidate(CloudHistoryReset.parameters);
    _motion();
    _context.invalidate();
  }

  CloudAppearance get appearance => _appearance;
  set appearance(CloudAppearance value) {
    _check();
    _appearance = value;
    _revision++;
    _history.invalidate(CloudHistoryReset.parameters);
    _context.invalidate();
  }

  /// Pauses weather, shape and detail motion without changing their velocities.
  bool get animationEnabled => _animationEnabled;
  set animationEnabled(bool value) {
    _check();
    if (value == _animationEnabled) return;
    _animationEnabled = value;
    _skipAnimationDelta = true;
    _revision++;
    _history.invalidate(CloudHistoryReset.parameters);
    _motion();
    _context.invalidate();
  }

  /// Active cloud motion time, excluding paused time and bounded by frame delta.
  Duration get animationElapsed => _animationElapsed;

  bool get adaptiveEnabled => _frameBudget != null;
  void setSceneFrameBudget(CloudSceneFrameBudget? budget) {
    _check();
    _frameBudget = budget == null ? null : CloudSceneFrameController(budget);
    _context.invalidate();
  }

  Map<String, Object?> get adaptiveDiagnostics => {
    'enabled': adaptiveEnabled,
    'requestedPreset': _quality.name,
    'effectiveRayStride': _displayed?.rayStride ?? 4,
    'effectiveWidth': _displayed?.temporal.width,
    'effectiveHeight': _displayed?.temporal.height,
    'effectiveShadowCadence': _displayed?.shadowCadence ?? 1,
    'shadowUpdate': _displayed?.shadow.updateReason,
    'shadowUpdated': _displayed?.shadow.updated,
    'presentedHistoryFrames': _displayed?.history.status.accumulatedFrames ?? 0,
    if (_frameBudget != null) ..._frameBudget!.toJson(),
  };

  CloudQualityPreset get quality => _quality;
  int get maxResolution => _maxResolution;
  int? get shadowMapSize => _shadowMapSize;
  bool get shadowsEnabled => _shadowsEnabled;
  CloudQualityPreset get shadowQuality => _shadowQuality ?? _quality;
  int get width => _width;
  int get height => _height;
  CloudQualitySettings get settings => CloudQualitySettings(
    preset: _quality,
    maxResolution: _maxResolution,
    maxPixels: _maxPixels,
    shadowMapSize: _shadowMapSize,
    shadowsEnabled: _shadowsEnabled,
    shadowPreset: _shadowQuality,
  );
  CloudTemporalSettings get temporal => _temporal;
  CloudHistoryStatus get history => _history.status;
  void resetHistory() {
    _check();
    _history.invalidate();
    for (final candidate in _candidates) {
      if (!identical(candidate, _active)) candidate.history.invalidate();
    }
    _motion();
    _context.invalidate();
  }

  Future<void> setTemporal(CloudTemporalSettings settings) => _serial(() async {
    await _replace(
      _quality,
      _textures!.textures,
      _width,
      _height,
      temporal: settings,
    );
    _temporal = settings;
    _motion();
    _context.invalidate();
  });
  void _check() {
    if (isClosed) {
      throw StateError('Cloud controller has closed.');
    }
  }

  Future<T> _serial<T>(Future<T> Function() action) {
    final next = _queue.then((_) {
      _check();
      return action();
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _initialize() => _serial(() async {
    if (_plugin.source case final source?) {
      _textures = await CloudTextures.load(
        _owner,
        source,
        cancellation: _sourceCancellation,
      );
    } else {
      _textures =
          await (_plugin.textures?.retain(_owner) ??
              CloudTextures.generate(_owner, isCancelled: () => isClosed));
    }
    _blueNoise =
        _plugin.blueNoise ??
        await _plugin.blueNoiseSource?.load(cancellation: _sourceCancellation);
    await _replace(_quality, _textures!.textures, _width, _height);
    await _bind(_active!);
    _motion();
  });
  void _motion() {
    final moving =
        _animationEnabled &&
        (_parameters.localWeatherVelocity != (0.0, 0.0) ||
            _parameters.shapeVelocity != Vec3.zero ||
            _parameters.shapeDetailVelocity != Vec3.zero);
    if (moving ||
        (_temporal.mode != CloudTemporalMode.off &&
            _history.status.accumulatedFrames < 16)) {
      _demand ??= _context.acquireFrameDemand();
    } else {
      _demand?.dispose();
      _demand = null;
    }
  }

  Future<void> setTextures(CloudTextures textures) => _serial(() async {
    final candidate = await textures.retain(_owner);
    try {
      await _replace(_quality, candidate.textures, _width, _height);
      final previous = _textures;
      _textures = candidate;
      await previous?.close();
      _context.invalidate();
    } catch (_) {
      if (!identical(_textures, candidate)) {
        await candidate.close();
      }
      rethrow;
    }
  });
  Future<void> setQuality(CloudQualityPreset value) => _serial(() async {
    if (value == _quality) {
      return;
    }
    await _replace(value, _textures!.textures, _width, _height);
    _quality = value;
    _motion();
    _context.invalidate();
  });

  /// Replace sampling quality and target limits together. Failed allocation
  /// leaves the active settings intact. Successful changes restart refinement.
  Future<void> setQualitySettings(CloudQualitySettings value) => _serial(
    () async {
      if (value.preset == _quality &&
          value.maxResolution == _maxResolution &&
          value.maxPixels == _maxPixels &&
          value.shadowMapSize == _shadowMapSize &&
          value.shadowsEnabled == _shadowsEnabled &&
          value.shadowPreset == _shadowQuality) {
        return;
      }
      final (width, height) = value.targetSize(_viewportWidth, _viewportHeight);
      await _replace(
        value.preset,
        _textures!.textures,
        width,
        height,
        settings: value,
      );
      _quality = value.preset;
      _maxResolution = value.maxResolution;
      _maxPixels = value.maxPixels;
      _shadowMapSize = value.shadowMapSize;
      _shadowsEnabled = value.shadowsEnabled;
      _shadowQuality = value.shadowPreset;
      _width = width;
      _height = height;
      _motion();
      _context.invalidate();
    },
  );
  Future<void> _replace(
    CloudQualityPreset quality,
    CloudTextures textures,
    int width,
    int height, {
    CloudTemporalSettings? temporal,
    CloudQualitySettings? settings,
  }) async {
    final scope = _owner.createChild(label: 'cloud scene');
    AtmosphereLutLease? lease;
    _CloudCandidate? candidate;
    try {
      lease = await _atmosphere.acquireLighting(isCancelled: () => isClosed);
      candidate = await _CloudCandidate.build(
        scope,
        lease,
        textures,
        CloudQuality.forPreset(
          quality,
          shadowsEnabled: settings?.shadowsEnabled ?? _shadowsEnabled,
          shadowPreset: settings != null
              ? settings.shadowPreset
              : _shadowQuality,
        ),
        width,
        height,
        settings != null ? settings.shadowMapSize : _shadowMapSize,
        _atmosphere.source,
        temporal ?? _temporal,
        _blueNoise,
      );
      _check();
      _active = candidate;
      _candidates.add(candidate);
      _history.invalidate(CloudHistoryReset.parameters);
      await _retireCandidates();
    } catch (_) {
      if (!identical(_active, candidate)) {
        await scope.close();
        await lease?.close();
      }
      rethrow;
    }
  }

  // Registration changes happen only during frame preparation. Setters can
  // prepare a new request while later hooks or the backend await, but cannot
  // change the candidate that the engine is about to capture.
  Future<void> _bind(_CloudCandidate candidate) async {
    if (identical(_bound, candidate)) return;
    if (_composition == null) {
      _composition = await _atmosphere.registerCloudInputs(candidate.inputs);
    } else {
      await _composition!.replace(candidate.inputs);
    }
    if (_producer == null) {
      _producer = _context.scene.addEffect(candidate.effect, order: -100);
    } else {
      _producer!.replace(candidate.effect);
    }
    if (_resolve == null) {
      _resolve = _context.scene.addEffect(
        candidate.temporal.resolve,
        order: -90,
      );
      _publish = _context.scene.addEffect(
        candidate.temporal.publish,
        order: -80,
      );
    } else {
      _resolve!.replace(candidate.temporal.resolve);
      _publish!.replace(candidate.temporal.publish);
    }
    _bound = candidate;
  }

  Future<void> _retireCandidates() async {
    final retained = <_CloudCandidate?>{
      _active,
      _bound,
      _displayed,
      _submission?.candidate,
      _submission?.displayed,
    };
    for (final candidate in _candidates.toList()) {
      if (!retained.contains(candidate)) {
        _candidates.remove(candidate);
        await candidate.close();
      }
    }
  }

  Future<void> _frame(FrameInfo info) => _serial(() async {
    // SceneEngine permits only one frame at a time. Any record left here belongs
    // to an aborted frame; successful receipts have already reached every hook.
    _submission = null;
    if (_animationEnabled && !_skipAnimationDelta) {
      _animationElapsed += info.delta;
    }
    _skipAnimationDelta = false;
    _viewportWidth = info.width;
    _viewportHeight = info.height;
    final (width, height) = settings.targetSize(info.width, info.height);
    if (width != _width ||
        height != _height ||
        _active!.lease.luts.parameters.key != _atmosphere.parameters.key ||
        !identical(_active!.source, _atmosphere.source)) {
      await _replace(_quality, _textures!.textures, width, height);
      _width = width;
      _height = height;
    }
    final candidate = _active!;
    await _bind(candidate);
    final frame = await _prepareCandidate(candidate, info);
    final displayed = _displayed;
    final displayedFrame = displayed == null
        ? null
        : identical(displayed, candidate)
        ? frame
        : await _prepareCandidate(displayed, info);
    _submission = _CloudSubmission(
      info.number,
      candidate,
      frame,
      displayed,
      displayedFrame,
    );
    await _retireCandidates();
  });

  Future<CloudHistoryFrame> _prepareCandidate(
    _CloudCandidate candidate,
    FrameInfo info,
  ) async {
    final camera = _context.camera,
        ecef = cloudPoint(_atmosphere.worldToEcef, camera.position);
    var corrected = ecef;
    if (_atmosphere.correctAltitude) {
      final surface = _atmosphere.ellipsoid.projectOnSurface(ecef);
      corrected =
          ecef -
          surface +
          _atmosphere.ellipsoid.surfaceNormal(surface) *
              _atmosphere.parameters.bottomRadius;
    }
    final directions = CelestialDirections.at(
      _atmosphere.date,
      observerECEF: ecef,
    );
    final sun = directions.sunECEF;
    final lunar = lunarIrradianceScale(directions, _atmosphere.appearance);
    final nightFill = _atmosphere.appearance.nightLightIntensity;
    final history = candidate.history.begin(
      camera: camera,
      moon: lunar > 0 ? directions.moonECEF : null,
      lunarIrradiance: lunar,
      nightLightIntensity: nightFill,
      aspect: info.width / info.height,
      width: candidate.temporal.width,
      height: candidate.temporal.height,
      number: info.number,
      elapsed: _animationElapsed,
      revision: _revision,
      epoch: _context.scene.renderSettings.historyEpoch,
      sun: sun,
      settings: candidate.settings,
    );
    final previous = history.valid ? candidate.history.previous : null;
    final parameters = _parameters, appearance = _appearance;
    candidate.rayStride = candidate.settings.mode == CloudTemporalMode.upscale
        ? _frameBudget?.rayStride ?? 4
        : 1;
    await candidate.temporal.prepare(
      history,
      candidate.settings,
      rayStride: candidate.rayStride,
    );
    final state = CloudFrameState(
      camera: camera,
      worldToEcef: _atmosphere.worldToEcef,
      correctedCamera: corrected,
      sun: sun,
      moon: directions.moonECEF,
      moonIrradiance: lunar,
      nightIrradiance: nightFill,
      bottomRadius: _atmosphere.parameters.bottomRadius,
      aspect: info.width / info.height,
      width: candidate.temporal.width,
      height: candidate.temporal.height,
      shadowSize: candidate.shadow.size,
      cascadeCount: candidate.shadow.quality.shadow.cascadeCount,
      shadowsEnabled: candidate.shadow.quality.shadowsEnabled,
      shadowFarScale: _plugin.shadowFarScale,
      frame: candidate.settings.mode == CloudTemporalMode.off ? 0 : info.number,
      previousViewProjection: previous?.viewProjection,
      previousCamera: previous?.position,
    );
    candidate.shadowCadence = _frameBudget?.shadowCadence ?? 1;
    await candidate.shadow.render(
      parameters,
      appearance,
      state,
      elapsed: _animationElapsed.inMicroseconds / 1e6,
      historyValid: history.valid,
      cadence: candidate.shadowCadence,
      animated:
          _animationEnabled &&
          (_parameters.localWeatherVelocity != (0.0, 0.0) ||
              _parameters.shapeVelocity != Vec3.zero ||
              _parameters.shapeDetailVelocity != Vec3.zero),
    );
    return history;
  }

  Future<void> _presented(int number, FrameStats stats) => _serial(() async {
    final submitted = _submission;
    if (submitted == null || submitted.number != number) {
      throw StateError('Cloud receipt does not match the prepared frame.');
    }
    _frameBudget?.observe(stats);
    final retained = stats.admission?.candidateReady == false;
    final candidate = retained ? submitted.displayed : submitted.candidate;
    final frame = retained ? submitted.displayedFrame : submitted.frame;
    if (candidate != null && frame != null) {
      candidate.history.present(frame, _revision);
      _displayed = candidate;
      _motion();
    }
    _submission = null;
    await _retireCandidates();
  });

  Future<void> _close() async {
    _closed = true;
    _sourceCancellation.cancel();
    _demand?.dispose();
    await _queue;
    _producer?.dispose();
    _resolve?.dispose();
    _publish?.dispose();
    try {
      await _composition?.close();
    } finally {
      for (final candidate in _candidates) {
        await candidate.close();
      }
      _candidates.clear();
      await _textures?.close();
      await _owner.close();
    }
  }
}

final class _CloudSubmission {
  final int number;
  final _CloudCandidate candidate;
  final CloudHistoryFrame frame;
  final _CloudCandidate? displayed;
  final CloudHistoryFrame? displayedFrame;
  const _CloudSubmission(
    this.number,
    this.candidate,
    this.frame,
    this.displayed,
    this.displayedFrame,
  );
}

final class _CloudCandidate {
  final GpuScope scope;
  final AtmosphereLutLease lease;
  final PrecomputedAtmosphereSource? source;
  final CloudShadowPass shadow;
  final ScreenEffect effect;
  final AtmosphereCloudInputs inputs;
  final CloudTemporalPass temporal;
  final CloudTemporalSettings settings;
  final history = CloudHistory();
  int rayStride = 4, shadowCadence = 1;
  _CloudCandidate(
    this.scope,
    this.lease,
    this.source,
    this.shadow,
    this.effect,
    this.inputs,
    this.temporal,
    this.settings,
  );
  static Future<_CloudCandidate> build(
    GpuScope scope,
    AtmosphereLutLease lease,
    CloudTextures textures,
    CloudQuality quality,
    int width,
    int height,
    int? shadowMapSize,
    PrecomputedAtmosphereSource? source,
    CloudTemporalSettings settings,
    CloudBlueNoise? blueNoise,
  ) async {
    final shadow = await CloudShadowPass.build(
      scope,
      textures,
      quality,
      mapSize: shadowMapSize,
      blueNoise: blueNoise,
      temporal: settings.mode != CloudTemporalMode.off,
    );
    final rawWidth = settings.mode == CloudTemporalMode.upscale
            ? (width + 3) ~/ 4
            : width,
        rawHeight = settings.mode == CloudTemporalMode.upscale
            ? (height + 3) ~/ 4
            : height;
    Future<GpuResource<Texture>> target(TextureFormat format) =>
        scope.resources.createTexture(
          TextureDescriptor(
            width: rawWidth,
            height: rawHeight,
            format: format,
            usage: {
              TextureUsage.storage,
              TextureUsage.sampled,
              TextureUsage.copySource,
              if (format == TextureFormat.rgba16Float)
                TextureUsage.renderAttachment,
            },
          ),
        );
    final color = await target(TextureFormat.rgba16Float),
        data = await target(TextureFormat.rgba32Float),
        transmittance = await target(TextureFormat.r32Float);
    final inputs = AtmosphereCloudInputs(
      color: color,
      depthVelocityShadow: data,
      transmittance: transmittance,
    );
    final temporal = await CloudTemporalPass.build(
      scope,
      inputs,
      width,
      height,
    );
    final library = lease.luts.shader();
    final program = await scope.shaders.compile(
      ShaderSource.wgsl(
        PostProcessDescriptor.interfaceWgsl +
            library.source +
            cloudMediaMathWgsl(quality) +
            cloudFrameWgsl +
            cloudBlueNoiseWgsl +
            cloudTemporalUniformWgsl +
            cloudSamplingShader(shadow.textures.textures) +
            cloudShadowSamplingWgsl(
              quality.shadow.cascadeCount,
              enabled: quality.shadowsEnabled,
            ) +
            cloudRenderWgsl(quality),
        label: 'volumetric clouds',
      ),
    );
    final effect = await scope.materials.compileEffect(
      PostProcessDescriptor(
        program: program,
        target: color,
        bindings: ShaderBindings([
          ...library.bindings.entries,
          ...shadow.bindings,
          BufferBinding.uniform(8, temporal.uniform, group: 2),
          if (shadow.atlas case final atlas?)
            TextureBinding.sampled(6, atlas, group: 2),
          TextureBinding.storage(1, data, group: 3),
          TextureBinding.storage(2, transmittance, group: 3),
        ]),
      ),
    );
    return _CloudCandidate(
      scope,
      lease,
      source,
      shadow,
      effect,
      temporal.outputs,
      temporal,
      settings,
    );
  }

  Future<void> close() async {
    try {
      await scope.close();
    } finally {
      await lease.close();
    }
  }
}

final class _CloudSourceCancellation implements LoadCancellation {
  final _callbacks = <Object, void Function()>{};
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
      return Registration(() {});
    }
    final key = Object();
    _callbacks[key] = callback;
    return Registration(() => _callbacks.remove(key));
  }

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    final pending = _callbacks.values.toList();
    _callbacks.clear();
    for (final callback in pending) {
      try {
        callback();
      } catch (_) {
        // Cleanup still waits for the physical source request to settle.
      }
    }
  }
}
