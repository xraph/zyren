import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/surfaces.dart';
import '../presentation.dart';
import 'output_presenter.dart';

const _channel = MethodChannel('gpu3d/android-surfaces');
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
class NativeAndroidBackend implements RenderBackend {
  final int session;
  final String adapter;
  final String? driver;
  final _encoder = ScenePacketEncoder(viewId: 1);
  bool _closed = false;
  int _nextFrame = 0, _nextAttachment = 0;
  Future<FrameOutput>? _drawing;
  Future<void>? _closing;
  NativeAndroidBackend._(this.session, this.adapter, this.driver);

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
      return NativeAndroidBackend._(
        result['session'] as int,
        result['adapter'] as String,
        result['driverInfo'] as String?,
      );
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
    backend: 'Vulkan',
    adapterName: adapter,
    driverDescription: driver,
    features: {
      RenderFeature.sharedTexture,
      RenderFeature.indexedMeshes,
      RenderFeature.diffuseLighting,
      RenderFeature.unlitMaterials,
      RenderFeature.colorTextures,
      RenderFeature.alphaMaterials,
      RenderFeature.portablePrimitives,
    },
    limits: DeviceLimits(
      maxTextureDimension2D: 4096,
      maxGeometryBytes: 64 * 1024 * 1024,
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
        error.code == SceneIssueCodes.frameDeferred
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
    final frame = ++_nextFrame;
    final pending = request<Map>('render', {
      'scene': packet.bytes,
      'frame': frame,
      'attachment': key.attachment,
      'epoch': target.epoch,
      'width': submission.size.width,
      'height': submission.size.height,
    });
    clock.stop();
    final result = (await pending)!;
    if (result['applied'] == true) _encoder.accept(packet);
    if (_closed || result['presented'] != true) throw _deferred();
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
        drawCalls: submission.scene.drawCalls,
        triangles: submission.scene.triangles,
        readbackBytes: result['readbackBytes'] as int,
        uploadedBytes: packet.uploadedBytes,
      ),
    );
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    final drawing = _drawing;
    await Future.wait<void>([
      request<void>('close'),
      if (drawing != null)
        drawing.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    ]);
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
