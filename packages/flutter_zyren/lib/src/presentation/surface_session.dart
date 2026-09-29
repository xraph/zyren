import 'dart:async';
import 'package:zyren/rendering.dart';

enum SurfaceSessionState { creating, ready, suspended, closing, closed, failed }

/// The texture ID belongs to Flutter. The key belongs to the native registry.
final class SurfaceAttachment {
  final SurfaceKey key;
  final int textureId, epoch;
  final PhysicalSize size;
  final bool suspended;
  const SurfaceAttachment({
    required this.key,
    required this.textureId,
    required this.epoch,
    required this.size,
    required this.suspended,
  });
}

/// Platform operations own native references; Dart never acknowledges GPU use.
abstract interface class SurfaceBridge {
  Future<int> runtimeToken();
  Future<SurfaceAttachment> create(PhysicalSize size);
  Future<SurfaceAttachment> resize(
    SurfaceAttachment surface,
    PhysicalSize size,
  );
  Future<SurfaceAttachment> suspend(SurfaceAttachment surface, bool suspended);
  Future<void> close(SurfaceAttachment surface);
}

/// Serializes attachment changes and keeps only the latest desired viewport.
/// Platform registration is supplied by an adapter after its GPU path qualifies.
final class SurfaceSession {
  final SurfaceBridge _bridge;
  final int _runtimeToken;
  PhysicalSize _desiredSize;
  bool _desiredSuspended = false, _closing = false;
  SurfaceSessionState _state = SurfaceSessionState.creating;
  SurfaceAttachment? _attached;
  Object? _failure;
  int _requestRevision = 0;
  Future<void>? _operation, _closeFuture;
  late final Future<void> ready;

  SurfaceSession({
    required SurfaceBridge bridge,
    required int runtimeToken,
    required PhysicalSize size,
  }) : _bridge = bridge,
       _runtimeToken = runtimeToken,
       _desiredSize = size {
    ready = _initialize();
    // A caller may dispose before awaiting ready. Keep the failure observable
    // through ready without reporting an unhandled asynchronous error.
    unawaited(ready.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
  }
  SurfaceSessionState get state => _state;
  SurfaceAttachment? get attachment =>
      _state == SurfaceSessionState.ready ||
          _state == SurfaceSessionState.suspended
      ? _attached
      : null;

  Future<void> _initialize() async {
    try {
      final token = await _bridge.runtimeToken();
      if (_closing) throw _disposed();
      if (token == 0 || token != _runtimeToken) {
        throw SceneException(
          SceneIssue(
            code: SceneIssueCodes.presentationUnavailable,
            operation: 'surface.attach',
            message:
                'The Flutter plugin and renderer loaded different native runtimes.',
          ),
        );
      }
      _attached = await _bridge.create(_desiredSize);
      if (_closing) throw _disposed();
      await _reconcile();
      if (_closing) throw _disposed();
    } catch (error) {
      _failure = error;
      if (!_closing) _state = SurfaceSessionState.failed;
      rethrow;
    }
  }

  Future<void> resize(PhysicalSize size) {
    if (_closing) return Future.error(_disposed());
    if (_failure != null) return Future.error(_failure!);
    _desiredSize = size;
    _requestRevision++;
    return _schedule();
  }

  Future<void> setSuspended(bool suspended) {
    if (_closing) return Future.error(_disposed());
    if (_failure != null) return Future.error(_failure!);
    _desiredSuspended = suspended;
    _requestRevision++;
    return _schedule();
  }

  Future<void> _schedule() => _operation ??= _apply();
  Future<void> _apply() async {
    try {
      await ready;
      while (!_closing) {
        final revision = _requestRevision;
        await _reconcile();
        if (revision == _requestRevision) break;
      }
    } catch (error) {
      _failure = error;
      if (!_closing) _state = SurfaceSessionState.failed;
      rethrow;
    } finally {
      _operation = null;
    }
  }

  Future<void> _reconcile() async {
    while (!_closing) {
      final surface = _attached!;
      final size = _desiredSize;
      if (surface.size.width != size.width ||
          surface.size.height != size.height) {
        _attached = await _bridge.resize(surface, size);
        continue;
      }
      if (surface.suspended != _desiredSuspended) {
        _attached = await _bridge.suspend(surface, _desiredSuspended);
        continue;
      }
      _state = surface.suspended
          ? SurfaceSessionState.suspended
          : SurfaceSessionState.ready;
      return;
    }
  }

  Future<void> close() {
    if (_closeFuture != null) return _closeFuture!;
    _closing = true;
    _state = SurfaceSessionState.closing;
    return _closeFuture = _close();
  }

  Future<void> _close() async {
    try {
      await ready;
    } catch (_) {
      /* Failed creation may still own an attachment. */
    }
    try {
      await _operation;
    } catch (_) {
      /* Retire after an unsuccessful mutation. */
    }
    try {
      final surface = _attached;
      if (surface != null) await _bridge.close(surface);
      _attached = null;
      _state = SurfaceSessionState.closed;
    } catch (_) {
      _state = SurfaceSessionState.failed;
      rethrow;
    }
  }

  SceneException _disposed() => SceneException(
    SceneIssue(
      code: SceneIssueCodes.disposed,
      operation: 'surface',
      message: 'The surface session is closing.',
    ),
  );
}
