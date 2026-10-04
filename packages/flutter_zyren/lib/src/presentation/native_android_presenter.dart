import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren/zyren.dart'
    show
        ResourceScope,
        ShaderCompiler,
        GraphCompiler,
        MaterialCompiler,
        TextureFormat;
import 'package:zyren_native/surfaces.dart';
import 'package:zyren_native/zyren_native.dart';
import '../presentation.dart';
import 'output_presenter.dart';
import 'native_gpu_transport.dart';

const _channel = MethodChannel('zyren/android-surfaces');
SceneException _issue(String code, String message, String operation) =>
    SceneException(
      SceneIssue(code: code, message: message, operation: operation),
    );
SceneException _deferred() => _issue(
  SceneIssueCodes.frameDeferred,
  'The Android surface changed before the frame could be presented.',
  'present',
);

/// Controller-owned Vulkan renderer. Select through SceneRuntime.nativeAndroid().
class NativeAndroidBackend
    implements NativeGpuBackend, SceneUploadBudgetBackend, CaptureBackend {
  final int session;
  Set<TextureFormat> _textureFormats = const {};
  Set<int> _sampleCounts = const {1};
  final String adapter;
  final String? driver;
  late final _encoder = _gpu.createSceneEncoder(viewId: 1);
  bool _closed = false;
  int _nextFrame = 0, _nextAttachment = 0;
  Future<FrameOutput>? _drawing;
  Future<void>? _closing;
  late final _gpu = nativeGpuServices(
    (args) async => (await request<Map>('gpuCommand', args))!,
  );
  NativeAndroidBackend._(this.session, this.adapter, this.driver);

  @override
  Future<SceneCaptureView> createCaptureView() => _gpu.createCaptureView();

  @override
  void configureSceneUploadBudget(int bytes) {
    if (_closed) throw StateError('Native view has closed.');
    _encoder.uploadBudgetBytes = bytes;
  }

  @override
  ResourceScope createResourceScope({String label = ''}) =>
      _gpu.createResourceScope(label: label);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      _gpu.createShaderCompiler(label: label);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      _gpu.createGraphCompiler(label: label);
  @override
  MaterialCompiler createMaterialCompiler({String label = ''}) =>
      _gpu.createMaterialCompiler(label: label);
  @override
  Future<GpuInspection> inspectGpu({int allocationLimit = 128}) {
    if (_closed) throw StateError('Native view has closed.');
    return _gpu.inspectGpu(allocationLimit: allocationLimit);
  }

  @override
  Future<ResourceStats> resourceStats() => _gpu.resourceStats();
  @override
  Future<void> configureResourceBudget(int bytes) =>
      _gpu.configureResourceBudget(bytes);
  @override
  Future<ShaderStats> shaderStats() => _gpu.shaderStats();
  @override
  Future<GraphCacheStats> graphStats() => _gpu.graphStats();

  @override
  Future<ShadowStats> shadowStats() => _gpu.shadowStats();

  @override
  Future<TemporalStats> temporalStats() => _gpu.temporalStats();

  @override
  Future<TransmissionStats> transmissionStats() => _gpu.transmissionStats();

  static Future<NativeAndroidBackend> create({int? runtimeToken}) async {
    if (defaultTargetPlatform != TargetPlatform.android) {
      throw _issue(
        SceneIssueCodes.backendUnavailable,
        'The Vulkan surface runtime requires Android.',
        'create',
      );
    }
    try {
      await _channel.invokeMethod<void>('connect', {
        'runtime': runtimeToken ?? NativeSurfaces().runtimeToken,
      });
      final result = (await _channel.invokeMapMethod<Object?, Object?>(
        'create',
        {'deferredAttachment': true},
      ))!;
      final backend = NativeAndroidBackend._(
        result['session'] as int,
        result['adapter'] as String,
        result['driverInfo'] as String?,
      );
      try {
        backend._textureFormats = await backend._gpu.textureFormats();
        backend._sampleCounts = (await backend._gpu.deviceInfo()).sampleCounts;
        return backend;
      } catch (_) {
        await backend.close();
        rethrow;
      }
    } on PlatformException catch (error) {
      throw _issue(
        SceneIssueCodes.backendUnavailable,
        error.message ?? error.code,
        'create',
      );
    } on MissingPluginException catch (error) {
      throw _issue(
        SceneIssueCodes.backendUnavailable,
        error.message ?? 'Android surface plugin is unavailable.',
        'create',
      );
    }
  }

  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'wgpu-native',
    textureFormats: _textureFormats,
    backend: 'Vulkan',
    adapterName: adapter,
    driverDescription: driver,
    features: {
      if (_sampleCounts.contains(4)) RenderFeature.multisampleAntialiasing,
      RenderFeature.shaderMaterials,
      RenderFeature.postprocessing,
      RenderFeature.punctualLights,
      RenderFeature.shadowMaps,
      RenderFeature.spatialAntialiasing,
      RenderFeature.bloom,
      RenderFeature.sectionClipping,
      RenderFeature.floatTextures,
      RenderFeature.volumeTextures,
      RenderFeature.hdr,
      RenderFeature.reversedDepth,
      RenderFeature.selectionOutlines,
      RenderFeature.sharedTexture,
      RenderFeature.indexedMeshes,
      RenderFeature.diffuseLighting,
      RenderFeature.unlitMaterials,
      RenderFeature.colorTextures,
      RenderFeature.alphaMaterials,
      RenderFeature.portablePrimitives,
      RenderFeature.materialSidedness,
      RenderFeature.scopedResources,
      RenderFeature.shaderCompilation,
      RenderFeature.renderGraphs,
      RenderFeature.frameGraphs,
      RenderFeature.meshShaders,
      RenderFeature.meshSceneInputs,
      RenderFeature.scaledOpaqueCapture,
      RenderFeature.sceneCapture,
      RenderFeature.standardMaterials,
      RenderFeature.physicalMaterials,
      RenderFeature.areaLighting,
      RenderFeature.temporalAntialiasing,
      RenderFeature.hdrColor,
      RenderFeature.environmentLighting,
      RenderFeature.shadows,
      RenderFeature.instancing,
      RenderFeature.skinning,
      RenderFeature.morphTargets,
      RenderFeature.compute,
      RenderFeature.storageTextures,
    },
    limits: DeviceLimits(
      maxTextureDimension2D: 4096,
      maxTextureDimension3D: 256,
      sampleCounts: _sampleCounts,
      maxResidentResourceBytes: _gpu.resourceBudgetBytes,
      maxGeometryBytes: 64 * 1024 * 1024,
      maxInstances: 100000,
      maxJoints: 256,
      maxMorphTargets: 64,
      maxPunctualLights: 16,
      maxHemisphereLights: 4,
      maxAreaLights: 4,
    ),
  );

  Future<T?> request<T>(
    String method, [
    Map<String, Object> args = const {},
  ]) async {
    try {
      return await _channel.invokeMethod<T>(method, {
        'session': session,
        ...args,
      });
    } on PlatformException catch (error) {
      throw _issue(
        error.code == SceneIssueCodes.frameDeferred ||
                error.code == SceneIssueCodes.deviceLost
            ? error.code
            : SceneIssueCodes.renderFailed,
        error.message ?? error.code,
        method,
      );
    }
  }

  int reserveAttachment() => ++_nextAttachment;
  Future<(_AndroidKey, int)> prepare(int attachment, PhysicalSize size) async {
    if (_closed) throw _deferred();
    final data = (await request<Map>('prepare', {
      'attachment': attachment,
      'width': size.width,
      'height': size.height,
    }))!;
    if (_closed) throw _deferred();
    return (
      _AndroidKey(this, attachment, data['texture'] as int),
      data['epoch'] as int,
    );
  }

  @override
  Future<FrameOutput> render(FrameSubmission submission) {
    if (_closed) {
      return Future.error(
        _issue(
          SceneIssueCodes.disposed,
          'The native renderer is closed.',
          'render',
        ),
      );
    }
    if (_drawing != null) return Future.error(_deferred());
    final future = _render(submission);
    _drawing = future;
    return future.whenComplete(() => _drawing = null);
  }

  Future<FrameOutput> _render(FrameSubmission submission) async {
    final target = submission.target;
    if (target is! SurfaceTarget) {
      throw _issue(
        SceneIssueCodes.unsupportedFeature,
        'This Android runtime supports surface presentation only. Explicit capture is not available.',
        'render',
      );
    }
    final key = target.surface;
    if (key is! _AndroidKey || !identical(key.backend, this)) {
      throw _issue(
        SceneIssueCodes.presentationUnavailable,
        'This renderer does not own the surface.',
        'render',
      );
    }
    if (submission.size.width > 4096 || submission.size.height > 4096) {
      throw ArgumentError('Render dimensions exceed 4096.');
    }
    final clock = Stopwatch()..start();
    final packet = _encoder.encode(submission);
    submission = packet.submission;
    final frame = ++_nextFrame;
    final pending = _gpu.submitFrame(
      packet.submission,
      packet.bytes,
      (bytes) => request<Map>('render', {
        'scene': bytes,
        'frame': frame,
        'attachment': key.attachment,
        'epoch': target.epoch,
        'width': submission.size.width,
        'height': submission.size.height,
      }),
      scenePacket: packet,
    );
    clock.stop();
    final result = (await pending.catchError((Object error, StackTrace stack) {
      _encoder.reject(packet);
      Error.throwWithStackTrace(error, stack);
    }))!;
    if (result['applied'] == true) {
      _encoder.accept(packet);
    } else {
      _encoder.reject(packet);
    }
    if (_closed || result['presented'] != true) throw _deferred();
    if (result['frameProfileError'] case final String error) {
      throw _issue(SceneIssueCodes.renderFailed, error, 'frameProfile');
    }
    final encodedProfile = result['frameProfile'];
    final profile = encodedProfile == null
        ? await _gpu.frameProfile()
        : NativeGpuServices.decodeFrameProfile(
            encodedProfile as Uint8List,
            frameId: frame,
          );
    return PresentedOutput(
      surface: key,
      epoch: target.epoch,
      frameId: frame,
      stats: FrameStats(
        frameId: frame,
        surfaceEpoch: target.epoch,
        physicalSize: submission.size,
        presentationPath: PresentationPath.sharedTexture,
        cpuBuildTime: submission.cpuBuildTime,
        cpuSubmitTime: clock.elapsed,
        profile: profile,
        admission: _encoder.admission,
        gpuTime: profile.gpuTime,
        drawCalls:
            profile.sceneDrawCalls(
              submission.scene.drawCalls +
                  submission.scene.transmissionCaptureDraws,
            ) +
            (submission.temporalAA == null
                ? 0
                : submission.scene.temporalMotionDraws + 1) +
            submission.scene.alphaResolveDraws +
            submission.outputConversionDraws +
            (submission.graph?.drawCalls ?? 0) +
            profile.resizeCompositeDraws,
        computeDispatches: submission.graph?.dispatches ?? 0,
        triangles:
            submission.scene.triangles +
            submission.scene.transmissionCaptureTriangles +
            (submission.temporalAA == null
                ? 0
                : submission.scene.triangles + 1) +
            submission.scene.alphaResolveDraws +
            submission.outputConversionDraws +
            (submission.graph?.triangles ?? 0) +
            profile.resizeCompositeDraws,
        readbackBytes: result['readbackBytes'] as int,
        uploadedBytes: packet.uploadedBytes,
      ),
    );
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    final drawing = _drawing?.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    await closeNativeGpuServices(_gpu, () => request<void>('close'), drawing);
  }
}

class _AndroidKey implements SurfaceKey {
  final NativeAndroidBackend backend;
  final int attachment, texture;
  _AndroidKey(this.backend, this.attachment, this.texture);
}

class NativeAndroidPresenterFactory implements SurfacePresenterFactory {
  const NativeAndroidPresenterFactory();
  @override
  bool supports(RenderBackend backend) => backend is NativeAndroidBackend;
  @override
  OutputPresenter create(RenderBackend backend) =>
      _AndroidPresenter(backend as NativeAndroidBackend);
}

class _AndroidPresenter implements OutputPresenter {
  final NativeAndroidBackend backend;
  final int attachment;
  bool _closed = false, _suspended = false;
  SurfaceTarget? _target;
  Future<void>? _closing;
  _AndroidPresenter(this.backend) : attachment = backend.reserveAttachment();

  @override
  Future<OutputTarget> prepare(PhysicalSize size) async {
    if (_closed || _suspended) throw _deferred();
    final (key, epoch) = await backend.prepare(attachment, size);
    if (_closed || _suspended) throw _deferred();
    return _target = SurfaceTarget(key, epoch);
  }

  @override
  Future<PresentedFrame> present(FrameOutput output) async {
    if (_closed ||
        _suspended ||
        output is! PresentedOutput ||
        output.surface != _target?.surface ||
        output.epoch != _target?.epoch) {
      throw _deferred();
    }
    final accepted = await backend.request<bool>('present', {
      'attachment': attachment,
      'epoch': output.epoch,
      'frame': output.frameId,
    });
    if (accepted != true || _closed || _suspended) throw _deferred();
    return _TextureFrame((output.surface as _AndroidKey).texture);
  }

  @override
  Future<void> setSuspended(bool value) async {
    _suspended = value;
    if (!_closed) {
      await backend.request<void>('suspend', {
        'attachment': attachment,
        'suspended': value,
      });
    }
  }

  @override
  Future<void> dispose() {
    _closed = true;
    _target = null;
    return _closing ??= backend.request<void>('detach', {
      'attachment': attachment,
    });
  }
}

class _TextureFrame implements PresentedFrame {
  final int texture;
  _TextureFrame(this.texture);
  @override
  Widget build(BuildContext context) =>
      Texture(textureId: texture, filterQuality: FilterQuality.low);
  @override
  void dispose() {}
}
