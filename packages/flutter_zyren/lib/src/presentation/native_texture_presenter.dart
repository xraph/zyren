import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_native/surfaces.dart';
import '../presentation.dart';
import 'output_presenter.dart';
import 'surface_session.dart';

const _channel = MethodChannel('zyren/surfaces');

class NativeTexturePresenterFactory implements SurfacePresenterFactory {
  const NativeTexturePresenterFactory();
  @override
  bool supports(RenderBackend backend) =>
      backend is NativeBackend &&
      backend.capabilities.supports(RenderFeature.sharedTexture);
  @override
  OutputPresenter create(RenderBackend backend) =>
      NativeTexturePresenter(backend as NativeBackend);
}

class NativeTexturePresenter implements OutputPresenter {
  final NativeBackend backend;
  SurfaceSession? _session;
  bool _closed = false, _suspended = false;
  NativeTexturePresenter(this.backend);
  @override
  Future<OutputTarget> prepare(PhysicalSize size) async {
    if (_closed) throw StateError('Texture presenter has closed.');
    final session = _session ??= SurfaceSession(
      bridge: _AppleBridge(backend),
      runtimeToken: NativeSurfaces().runtimeToken,
      size: size,
    );
    await session.ready;
    await session.resize(size);
    await session.setSuspended(_suspended);
    final attachment = session.attachment;
    if (_closed || _suspended || attachment == null) throw _deferred();
    return SurfaceTarget(attachment.key, attachment.epoch);
  }

  @override
  Future<PresentedFrame> present(FrameOutput output) async {
    final attachment = _session?.attachment;
    if (output is! PresentedOutput) {
      throw StateError('Native texture requires a surface receipt.');
    }
    if (_closed ||
        _suspended ||
        attachment == null ||
        output.surface != attachment.key ||
        output.epoch != attachment.epoch) {
      throw _deferred();
    }
    final accepted = await _channel.invokeMethod<bool>('frameAvailable', {
      'key': (attachment.key as NativeSurfaceKey).toMessage(),
      'texture': attachment.textureId,
      'epoch': output.epoch,
    });
    if (accepted != true) throw _deferred();
    return _TextureFrame(attachment.textureId);
  }

  @override
  Future<void> setSuspended(bool value) async {
    _suspended = value;
    if (!_closed) await _session?.setSuspended(value);
  }

  @override
  Future<void> dispose() async {
    _closed = true;
    await _session?.close();
  }
}

SceneException _deferred() => SceneException(
  SceneIssue(
    code: SceneIssueCodes.frameDeferred,
    message: 'The surface changed before this frame could be presented.',
    operation: 'present',
  ),
);

class _TextureFrame implements PresentedFrame {
  final int id;
  _TextureFrame(this.id);
  @override
  Widget build(BuildContext context) =>
      Texture(textureId: id, filterQuality: FilterQuality.low);
  @override
  void dispose() {}
}

class _AppleBridge implements SurfaceBridge {
  final NativeBackend backend;
  final native = NativeSurfaces();
  _AppleBridge(this.backend);
  @override
  Future<int> runtimeToken() async => (await _channel.invokeMethod<int>(
    'connect',
    {'runtime': native.runtimeToken},
  ))!;
  SurfaceAttachment _attachment(NativeSurfaceSnapshot snapshot, int texture) =>
      SurfaceAttachment(
        key: snapshot.key,
        textureId: texture,
        epoch: snapshot.epoch,
        size: PhysicalSize(snapshot.width, snapshot.height),
        suspended: snapshot.state == NativeSurfaceState.suspended,
      );
  @override
  Future<SurfaceAttachment> create(PhysicalSize size) async {
    final surface = await backend.openSurface(size);
    try {
      final texture = await _channel.invokeMethod<int>('register', {
        'key': surface.key.toMessage(),
      });
      if (texture == null || texture < 0) {
        throw StateError('Native texture registration failed.');
      }
      return _attachment(surface, texture);
    } catch (_) {
      backend.closeSurface(surface);
      rethrow;
    }
  }

  @override
  Future<SurfaceAttachment> resize(
    SurfaceAttachment attachment,
    PhysicalSize size,
  ) async {
    final surface = native.read(attachment.key as NativeSurfaceKey);
    return _attachment(
      native.resize(surface, width: size.width, height: size.height),
      attachment.textureId,
    );
  }

  @override
  Future<SurfaceAttachment> suspend(
    SurfaceAttachment attachment,
    bool suspended,
  ) async {
    final surface = native.read(attachment.key as NativeSurfaceKey);
    return _attachment(
      native.suspend(surface, suspended: suspended),
      attachment.textureId,
    );
  }

  @override
  Future<void> close(SurfaceAttachment attachment) async {
    try {
      backend.closeSurface(native.read(attachment.key as NativeSurfaceKey));
    } on NativeSurfaceException catch (error) {
      if (error.code != 2) rethrow;
    } finally {
      await _channel.invokeMethod<void>('unregister', {
        'key': (attachment.key as NativeSurfaceKey).toMessage(),
        'texture': attachment.textureId,
      });
    }
  }
}
