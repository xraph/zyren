import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show PlatformViewHitTestBehavior;
import 'package:flutter/widgets.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/surfaces.dart';
import '../presentation.dart';
import 'output_presenter.dart';

const _channel = MethodChannel('gpu3d/scene-views');

SceneException _issue(String code, String message, String operation) =>
    SceneException(
      SceneIssue(code: code, message: message, operation: operation),
    );
SceneException _deferred() => _issue(
  SceneIssueCodes.frameDeferred,
  'The native view changed before this frame could be presented.',
  'present',
);

/// Apple channel transport for one controller-owned Rust renderer.
/// Applications select it through SceneRuntime.nativeMetal().
class NativeMetalBackend implements RenderBackend {
  final int session;
  final String adapter;
  final _encoder = ScenePacketEncoder(viewId: 1);
  bool _closed = false;
  int _nextFrame = 0, _nextAttachment = 0;
  Future<FrameOutput>? _drawing;
  Future<void>? _closing;
  NativeMetalBackend._(this.session, this.adapter);

  static Future<NativeMetalBackend> create({int? runtimeToken}) async {
    if (!Platform.isMacOS && !Platform.isIOS) {
      throw _issue(
        SceneIssueCodes.backendUnavailable,
        'The Metal view runtime requires macOS or iOS.',
        'create',
      );
    }
    try {
      await _channel.invokeMethod<void>('connect', {
        'runtime': runtimeToken ?? NativeSurfaces().runtimeToken,
      });
      final result = (await _channel.invokeMapMethod<Object?, Object?>(
        'create',
      ))!;
      return NativeMetalBackend._(
        result['session'] as int,
        result['adapter'] as String,
      );
    } on PlatformException catch (error) {
      throw _issue(
        SceneIssueCodes.backendUnavailable,
        error.message ?? error.code,
        'create',
      );
    }
  }

  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'wgpu-native',
    backend: 'Metal',
    adapterName: adapter,
    features: {
      RenderFeature.nativeView,
      RenderFeature.rgbaReadback,
      RenderFeature.indexedMeshes,
      RenderFeature.diffuseLighting,
      RenderFeature.unlitMaterials,
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

  int reserveView() => ++_nextAttachment;
  Future<SurfaceTarget> prepareView(
    int view,
    PhysicalSize size, {
    int attachment = 1,
  }) async {
    if (_closed) throw _deferred();
    final result = (await request<Map>('prepare', {
      'view': view,
      'attachment': attachment,
      'width': size.width,
      'height': size.height,
    }))!;
    return SurfaceTarget(
      _MetalKey(this, view, attachment),
      result['epoch'] as int,
    );
  }

  Future<void> detachView(int attachment) =>
      request<void>('detach', {'attachment': attachment});
  Future<void> suspendView(int attachment, bool value) =>
      request<void>('suspend', {'attachment': attachment, 'suspended': value});
  Future<bool> presentView(PresentedOutput output) async {
    final key = output.surface as _MetalKey;
    return await request<bool>('present', {
          'view': key.view,
          'attachment': key.attachment,
          'epoch': output.epoch,
          'frame': output.frameId,
        }) ==
        true;
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
    if (submission.size.width > 4096 || submission.size.height > 4096) {
      throw ArgumentError('Render dimensions exceed 4096.');
    }
    if (target is SurfaceTarget &&
        (target.surface is! _MetalKey ||
            !identical((target.surface as _MetalKey).backend, this))) {
      throw _issue(
        SceneIssueCodes.presentationUnavailable,
        'This renderer does not own the view.',
        'render',
      );
    }
    if (target is ReadbackTarget &&
        (target.format != PixelFormat.rgba8 ||
            target.colorSpace != ColorSpace.srgb)) {
      throw _issue(
        SceneIssueCodes.unsupportedFeature,
        'Capture supports RGBA8 sRGB.',
        'capture',
      );
    }
    final clock = Stopwatch()..start();
    final packet = _encoder.encode(submission);
    final frame = ++_nextFrame;
    final key = target is SurfaceTarget ? target.surface as _MetalKey : null;
    final pending = request<Map>(key == null ? 'capture' : 'render', {
      'json': packet.bytes,
      'frame': frame,
      'width': submission.size.width,
      'height': submission.size.height,
      if (key != null) ...{
        'view': key.view,
        'attachment': key.attachment,
        'epoch': (target as SurfaceTarget).epoch,
      },
    });
    clock.stop();
    final result = (await pending)!;
    if (result['applied'] == true) _encoder.accept(packet);
    if (result['ready'] != true) throw _deferred();
    final stats = FrameStats(
      frameId: frame,
      surfaceEpoch: target is SurfaceTarget ? target.epoch : 0,
      physicalSize: submission.size,
      presentationPath: key == null
          ? PresentationPath.readback
          : PresentationPath.nativeView,
      cpuBuildTime: submission.cpuBuildTime,
      cpuSubmitTime: clock.elapsed,
      drawCalls: submission.scene.drawCalls,
      triangles: submission.scene.triangles,
      readbackBytes: result['readbackBytes'] as int,
      uploadedBytes: packet.uploadedBytes,
    );
    if (key == null) {
      return ReadbackOutput(
        image: ImageData(
          pixels: result['pixels'] as Uint8List,
          size: submission.size,
        ),
        stats: stats,
      );
    }
    return PresentedOutput(
      surface: key,
      epoch: (target as SurfaceTarget).epoch,
      frameId: frame,
      stats: stats,
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

class _MetalKey implements SurfaceKey {
  final NativeMetalBackend backend;
  final int view, attachment;
  _MetalKey(this.backend, this.view, this.attachment);
}

class NativeMetalPresenterFactory implements SurfacePresenterFactory {
  const NativeMetalPresenterFactory();
  @override
  bool supports(RenderBackend backend) => backend is NativeMetalBackend;
  @override
  OutputPresenter create(RenderBackend backend) =>
      _MetalPresenter(backend as NativeMetalBackend);
}

class _MetalPresenter implements HostedOutputPresenter {
  final NativeMetalBackend backend;
  final int attachment;
  final _ready = Completer<int>();
  bool _cancelled = false, _suspended = false;
  Future<void>? _closing;
  SurfaceTarget? _target;
  late final Widget _host;
  _MetalPresenter(this.backend) : attachment = backend.reserveView() {
    // Cancellation can happen before prepare starts observing this future.
    _ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    final args = {'session': backend.session, 'attachment': attachment};
    _host = Platform.isMacOS
        ? AppKitView(
            key: ObjectKey(this),
            viewType: 'gpu3d/scene',
            creationParams: args,
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            onPlatformViewCreated: _created,
          )
        : UiKitView(
            key: ObjectKey(this),
            viewType: 'gpu3d/scene',
            creationParams: args,
            creationParamsCodec: const StandardMessageCodec(),
            hitTestBehavior: PlatformViewHitTestBehavior.transparent,
            onPlatformViewCreated: _created,
          );
  }
  void _created(int view) {
    if (!_ready.isCompleted) _ready.complete(view);
  }

  @override
  Widget build(BuildContext context) => _host;
  @override
  Future<OutputTarget> prepare(PhysicalSize size) async {
    final view = await _ready.future;
    if (_cancelled || _suspended) throw _deferred();
    final target = await backend.prepareView(
      view,
      size,
      attachment: attachment,
    );
    if (_cancelled || _suspended) throw _deferred();
    _target = target;
    return target;
  }

  @override
  Future<PresentedFrame> present(FrameOutput output) async {
    if (_cancelled ||
        _suspended ||
        output is! PresentedOutput ||
        output.surface != _target?.surface ||
        output.epoch != _target?.epoch) {
      throw _deferred();
    }
    if (!await backend.presentView(output)) throw _deferred();
    return _HostedFrame(_host);
  }

  @override
  Future<void> setSuspended(bool value) async {
    _suspended = value;
    if (!_cancelled) await backend.suspendView(attachment, value);
  }

  @override
  void cancelPending() {
    _cancelled = true;
    if (!_ready.isCompleted) _ready.completeError(_deferred());
  }

  @override
  Future<void> dispose() {
    cancelPending();
    return _closing ??= backend.detachView(attachment);
  }
}

class _HostedFrame implements PresentedFrame {
  final Widget host;
  _HostedFrame(this.host);
  @override
  Widget build(BuildContext context) => host;
  @override
  void dispose() {}
}
