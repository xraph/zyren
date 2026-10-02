import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import '../atmosphere/plugin.dart';
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
  final CloudTextureSource? source;
  final CloudBlueNoiseSource? blueNoiseSource;
  final CloudTextures? textures;
  final CloudBlueNoise? blueNoise;
  final int maxResolution;
  final int? shadowMapSize;
  final double shadowFarScale;
  CloudController? _controller;
  CloudPlugin({
    CloudParameters? parameters,
    CloudAppearance? appearance,
    CloudTemporalSettings? temporal,
    this.quality = CloudQualityPreset.medium,
    this.source,
    this.blueNoiseSource,
    this.textures,
    this.blueNoise,
    this.maxResolution = 384,
    this.shadowMapSize,
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
    RangeError.checkValueInInterval(maxResolution, 1, 1024, 'maxResolution');
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
  void afterRender(PluginContext context, FrameInfo info, FrameStats stats) =>
      controller._presented();
}

final class CloudController {
  final CloudPlugin _plugin;
  final PluginContext _context;
  final GpuScope _owner;
  final AtmosphereController _atmosphere;
  late CloudParameters _parameters = _plugin.parameters;
  late CloudAppearance _appearance = _plugin.appearance;
  late CloudQualityPreset _quality = _plugin.quality;
  late CloudTemporalSettings _temporal = _plugin.temporal;
  final _history = CloudHistory();
  int _revision = 0;
  CloudHistoryFrame? _pendingFrame;
  _CloudCandidate? _pendingCandidate;
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

  CloudQualityPreset get quality => _quality;
  CloudTemporalSettings get temporal => _temporal;
  CloudHistoryStatus get history => _history.status;
  void resetHistory() {
    _check();
    _history.invalidate();
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
    _motion();
  });
  void _motion() {
    final moving =
        _parameters.localWeatherVelocity != (0.0, 0.0) ||
        _parameters.shapeVelocity != Vec3.zero ||
        _parameters.shapeDetailVelocity != Vec3.zero;
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
    _context.invalidate();
  });
  Future<void> _replace(
    CloudQualityPreset quality,
    CloudTextures textures,
    int width,
    int height, {
    CloudTemporalSettings? temporal,
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
        CloudQuality.forPreset(quality),
        width,
        height,
        _plugin.shadowMapSize,
        _atmosphere.source,
        temporal ?? _temporal,
        _blueNoise,
      );
      _check();
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
          candidate.temporal.resolve[0],
          order: -90,
        );
        _publish = _context.scene.addEffect(
          candidate.temporal.publish[0],
          order: -80,
        );
      } else {
        _resolve!.replace(candidate.temporal.resolve[0]);
        _publish!.replace(candidate.temporal.publish[0]);
      }
      final previous = _active;
      _active = candidate;
      _revision++;
      _history.invalidate(CloudHistoryReset.parameters);
      await previous?.close();
    } catch (_) {
      if (!identical(_active, candidate)) {
        await scope.close();
        await lease?.close();
      }
      rethrow;
    }
  }

  Future<void> _frame(FrameInfo info) => _serial(() async {
    final scale = math.min(
      1.0,
      _plugin.maxResolution / math.max(info.width, info.height),
    );
    final width = math.max(1, (info.width * scale).round()),
        height = math.max(1, (info.height * scale).round());
    if (width != _width ||
        height != _height ||
        _active!.lease.luts.parameters.key != _atmosphere.parameters.key ||
        !identical(_active!.source, _atmosphere.source)) {
      await _replace(_quality, _textures!.textures, width, height);
      _width = width;
      _height = height;
    }
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
    final candidate = _active!;
    final sun = CelestialDirections.at(
      _atmosphere.date,
      observerECEF: ecef,
    ).sunECEF;
    final history = _history.begin(
      camera: camera,
      aspect: info.width / info.height,
      width: width,
      height: height,
      number: info.number,
      elapsed: info.elapsed,
      revision: _revision,
      epoch: _context.scene.renderSettings.historyEpoch,
      sun: sun,
      settings: _temporal,
    );
    final previous = history.valid ? _history.previous : null;
    final parameters = _parameters, appearance = _appearance;
    await candidate.temporal.prepare(history, _temporal);
    _resolve!.replace(candidate.temporal.resolve[candidate.temporal.pending]);
    _publish!.replace(candidate.temporal.publish[candidate.temporal.pending]);
    final state = CloudFrameState(
      camera: camera,
      worldToEcef: _atmosphere.worldToEcef,
      correctedCamera: corrected,
      sun: sun,
      bottomRadius: _atmosphere.parameters.bottomRadius,
      aspect: info.width / info.height,
      width: width,
      height: height,
      shadowSize: candidate.shadow.size,
      cascadeCount: candidate.shadow.quality.shadow.cascadeCount,
      shadowFarScale: _plugin.shadowFarScale,
      frame: _temporal.mode == CloudTemporalMode.off ? 0 : info.number,
      previousViewProjection: previous?.viewProjection,
      previousCamera: previous?.position,
    );
    await candidate.shadow.render(
      parameters,
      appearance,
      state,
      elapsed: info.elapsed.inMicroseconds / 1e6,
      historyValid: history.valid,
    );
    _pendingFrame = history;
    _pendingCandidate = candidate;
  });
  void _presented() {
    final frame = _pendingFrame, candidate = _pendingCandidate;
    if (frame != null && identical(candidate, _active)) {
      _history.present(frame, _revision);
      candidate!.temporal.presented();
      candidate.shadow.presented();
      _motion();
    }
    _pendingFrame = null;
    _pendingCandidate = null;
  }

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
      await _active?.close();
      await _textures?.close();
      await _owner.close();
    }
  }
}

final class _CloudCandidate {
  final GpuScope scope;
  final AtmosphereLutLease lease;
  final PrecomputedAtmosphereSource? source;
  final CloudShadowPass shadow;
  final ScreenEffect effect;
  final AtmosphereCloudInputs inputs;
  final CloudTemporalPass temporal;
  _CloudCandidate(
    this.scope,
    this.lease,
    this.source,
    this.shadow,
    this.effect,
    this.inputs,
    this.temporal,
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
            cloudSamplingWgsl +
            cloudShadowSamplingWgsl(quality.shadow.cascadeCount) +
            cloudRenderWgsl(quality),
        label: 'volumetric clouds',
      ),
    );
    final effect = await scope.materials.compileEffect(
      PostProcessDescriptor(
        program: program,
        bindings: ShaderBindings([
          ...library.bindings.entries,
          ...shadow.bindings,
          BufferBinding.uniform(8, temporal.uniform, group: 2),
          TextureBinding.sampled(6, shadow.atlas, group: 2),
          TextureBinding.storage(0, color, group: 3),
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
