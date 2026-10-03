import 'models.dart';
import 'raycast.dart';

/// The native adapter owns camera permissions, session state and anchor lifetime.
abstract interface class XrTransport {
  Future<Object?> invoke(String method, Map<String, Object?> arguments);
}

final class XrSession {
  final XrTransport _transport;
  final String id;
  bool _closing = false, _starting = false;
  Future<void>? _disposeFuture;
  XrSession._(this._transport, this.id);

  static Future<XrCapabilities> capabilities(XrTransport transport) async =>
      XrCapabilities.fromMessage(await transport.invoke('capabilities', {}));

  static Future<XrSession> create(XrTransport transport) async {
    final response = messageMap(await transport.invoke('create', {}));
    return XrSession._(transport, messageString(response, 'sessionId'));
  }

  /// Accepts a configuration. Tracking can still be unavailable or limited.
  /// Reset removes every app anchor and detected plane from the session origin.
  Future<void> start({
    XrConfiguration configuration = const XrConfiguration(),
    bool resetTracking = false,
  }) async {
    if (_starting) throw const XrException('busy', 'Start is already pending.');
    _starting = true;
    try {
      await _invoke('start', {
        ...configuration.toMessage(),
        'resetTracking': resetTracking,
      });
    } finally {
      _starting = false;
    }
  }

  /// Cancels an outstanding permission/start request without waiting for it.
  Future<void> pause() async => _invoke('pause');

  /// Returns the latest frame only. Inspect state, tracking and frame age before use.
  Future<XrSnapshot> snapshot() async =>
      XrSnapshot.fromMessage(await _invoke('snapshot'));

  Future<XrPlaneGeometry> planeGeometry(
    String planeId, {
    required int expectedRevision,
  }) async {
    if (planeId.isEmpty) throw ArgumentError.value(planeId, 'planeId');
    final geometry = XrPlaneGeometry.fromMessage(
      await _invoke('planeGeometry', {
        'planeId': planeId,
        'expectedRevision': expectedRevision,
      }),
    );
    if (geometry.planeId != planeId ||
        geometry.sessionRevision != expectedRevision) {
      throw const XrException('staleRevision', 'The native plane changed.');
    }
    return geometry;
  }

  Future<String> addAnchor(
    XrPose pose, {
    int? expectedRevision,
    double? expectedFrameTimestamp,
  }) async {
    final response = messageMap(
      await _invoke('addAnchor', {
        'transform': pose.matrix,
        'expectedRevision': ?expectedRevision,
        'expectedFrameTimestamp': ?expectedFrameTimestamp,
      }),
    );
    return messageString(response, 'anchorId');
  }

  Future<void> removeAnchor(String anchorId, {int? expectedRevision}) async {
    if (anchorId.isEmpty) throw ArgumentError.value(anchorId, 'anchorId');
    await _invoke('removeAnchor', {
      'anchorId': anchorId,
      'expectedRevision': ?expectedRevision,
    });
  }

  Future<Object?> _invoke(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_closing) {
      throw const XrException('disposed', 'The session is closing.');
    }
    final value = await _transport.invoke(method, {'sessionId': id, ...args});
    if (_closing) {
      throw const XrException('disposed', 'The session is closing.');
    }
    return value;
  }

  /// Disposal bypasses pending start so a permission dialog cannot retain a session.
  /// A failed native release can be retried by calling dispose again.
  Future<void> dispose() {
    _closing = true;
    return _disposeFuture ??= _dispose();
  }

  Future<void> _dispose() async {
    try {
      await _transport.invoke('dispose', {'sessionId': id});
    } catch (_) {
      _disposeFuture = null;
      rethrow;
    }
  }
}
