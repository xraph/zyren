import 'dart:async';
import 'package:zyren/zyren.dart';
import 'model.dart';
import 'protocol.dart';

/// Serializable camera pose and projection. The receiver owns viewport sizing.
final class SharedSceneCamera {
  final Map<String, dynamic> _json;
  SharedSceneCamera._(this._json);
  factory SharedSceneCamera.capture(Camera camera) {
    final json = <String, dynamic>{
      'position': camera.position.storage,
      'target': camera.target.storage,
      'up': camera.up.storage,
      'depth': camera.depthStrategy.name,
    };
    if (camera is PerspectiveCamera) {
      json.addAll({
        'kind': 'perspective',
        'fov': camera.fieldOfView,
        'near': camera.near,
        'far': camera.far,
        'zoom': camera.zoom,
      });
    } else if (camera is OrthographicCamera) {
      json.addAll({
        'kind': 'orthographic',
        'left': camera.left,
        'right': camera.right,
        'top': camera.top,
        'bottom': camera.bottom,
        'near': camera.near,
        'far': camera.far,
        'zoom': camera.zoom,
        'fitAspect':
            camera.projectionMatrix(1).storage[0] !=
            camera.projectionMatrix(2).storage[0],
      });
    } else {
      throw UnsupportedError('Unsupported shared camera projection.');
    }
    return SharedSceneCamera.fromJson(json);
  }
  factory SharedSceneCamera.fromJson(Object? value) {
    final source = boundedDecode(boundedEncode(value!, 4096), 4096);
    final camera = SharedSceneCamera._(source);
    camera.createCamera().viewProjection(1);
    return camera;
  }
  Map<String, dynamic> toJson() =>
      boundedDecode(boundedEncode(_json, 4096), 4096);
  Camera createCamera() {
    Vec3 vector(String key) {
      final a = numberArray(_json[key], 3);
      return Vec3(a[0], a[1], a[2]);
    }

    double number(String key) {
      final n = _json[key];
      if (n is! num || !n.isFinite) {
        throw const FormatException('Invalid camera number.');
      }
      return n.toDouble();
    }

    final position = vector('position'),
        target = vector('target'),
        up = vector('up');
    if ((target - position).length2 == 0 ||
        up.length2 == 0 ||
        (target - position).cross(up).length2 == 0) {
      throw const FormatException('Degenerate camera axes.');
    }
    final depth = DepthStrategy.values.byName(textValue(_json['depth']));
    if (_json['kind'] == 'perspective') {
      return PerspectiveCamera(
        position: position,
        target: target,
        up: up,
        fieldOfView: number('fov'),
        near: number('near'),
        far: number('far'),
        zoom: number('zoom'),
        depthStrategy: depth,
      );
    }
    if (_json['kind'] != 'orthographic' || _json['fitAspect'] is! bool) {
      throw const FormatException('Unsupported camera projection.');
    }
    return OrthographicCamera(
      position: position,
      target: target,
      up: up,
      left: number('left'),
      right: number('right'),
      top: number('top'),
      bottom: number('bottom'),
      verticalSize: _json['fitAspect'] == true
          ? number('top') - number('bottom')
          : null,
      near: number('near'),
      far: number('far'),
      zoom: number('zoom'),
      depthStrategy: depth,
    )..setFrustum(
      left: number('left'),
      right: number('right'),
      top: number('top'),
      bottom: number('bottom'),
    );
  }
}

final class ScenePresence {
  final String sessionId, label;
  final int sequence;
  final DateTime expiresAt;
  final SharedSceneCamera? camera;
  final SceneObjectId? selection;
  ScenePresence({
    required this.sessionId,
    required this.label,
    required this.sequence,
    required this.expiresAt,
    this.camera,
    this.selection,
  }) {
    checkText(sessionId, 'sessionId');
    checkText(label, 'label');
    checkRevision(sequence);
  }
  Map<String, Object?> toJson() => {
    'sessionId': sessionId,
    'label': label,
    'sequence': sequence,
    'expiresAt': expiresAt.toUtc().toIso8601String(),
    if (camera != null) 'camera': camera!.toJson(),
    if (selection != null) 'selection': selection!.toJson(),
  };
  factory ScenePresence.fromJson(Object? value) {
    final j = objectMap(value);
    return ScenePresence(
      sessionId: textValue(j['sessionId']),
      label: textValue(j['label']),
      sequence: revisionValue(j['sequence']),
      expiresAt: DateTime.parse(textValue(j['expiresAt'])),
      camera: j['camera'] == null
          ? null
          : SharedSceneCamera.fromJson(j['camera']),
      selection: j['selection'] == null
          ? null
          : SceneObjectId.fromJson(j['selection']),
    );
  }
}

abstract interface class ScenePresenceTransport {
  Future<List<ScenePresence>> participants();
  Future<void> publishPresence({
    required String sessionId,
    required String label,
    required int sequence,
    SharedSceneCamera? camera,
    SceneObjectId? selection,
  });
  Future<void> leave(String sessionId);
}

/// Expiring sessions are intentionally absent from the operation ledger.
final class ScenePresenceAuthority {
  final FutureOr<bool> Function(String principal) authorize;
  final DateTime Function() clock;
  final Duration lease, minimumInterval, permissionTimeout;
  final int capacity;
  final _entries = <String, (String, ScenePresence, DateTime, bool)>{};
  ScenePresenceAuthority({
    required this.authorize,
    DateTime Function()? clock,
    this.lease = const Duration(seconds: 30),
    this.minimumInterval = const Duration(milliseconds: 50),
    this.permissionTimeout = const Duration(seconds: 5),
    this.capacity = 100,
  }) : clock = clock ?? DateTime.now {
    if (lease <= Duration.zero ||
        lease > const Duration(minutes: 5) ||
        minimumInterval < Duration.zero ||
        capacity < 1 ||
        capacity > 1000 ||
        permissionTimeout <= Duration.zero) {
      throw ArgumentError('Invalid presence limits.');
    }
  }
  ScenePresenceTransport connect(String principal) {
    checkText(principal, 'principal');
    return _PresenceConnection(this, principal);
  }

  Future<void> _authorize(String principal) async {
    if (!await Future<bool>.sync(
      () => authorize(principal),
    ).timeout(permissionTimeout)) {
      throw const SceneAccessDenied();
    }
    _entries.removeWhere((_, value) => !value.$2.expiresAt.isAfter(clock()));
  }
}

final class _PresenceConnection implements ScenePresenceTransport {
  final ScenePresenceAuthority host;
  final String principal;
  _PresenceConnection(this.host, this.principal);
  @override
  Future<List<ScenePresence>> participants() async {
    await host._authorize(principal);
    return List.unmodifiable(
      host._entries.values.where((v) => v.$4).map((v) => v.$2),
    );
  }

  @override
  Future<void> publishPresence({
    required String sessionId,
    required String label,
    required int sequence,
    SharedSceneCamera? camera,
    SceneObjectId? selection,
  }) async {
    final update = ScenePresence(
      sessionId: sessionId,
      label: label,
      sequence: sequence,
      expiresAt: host.clock().add(host.lease),
      camera: camera,
      selection: selection,
    );
    await host._authorize(principal);
    final previous = host._entries[sessionId];
    if (previous != null) {
      if (previous.$1 != principal) throw const SceneAccessDenied();
      if (sequence <= previous.$2.sequence) throw const SceneRevisionMismatch();
      if (host.clock().difference(previous.$3) < host.minimumInterval) {
        throw StateError('Presence rate limit.');
      }
    } else if (host._entries.length >= host.capacity) {
      throw StateError('Presence capacity reached.');
    }
    host._entries[sessionId] = (principal, update, host.clock(), true);
  }

  @override
  Future<void> leave(String sessionId) async {
    await host._authorize(principal);
    final previous = host._entries[sessionId];
    if (previous == null) return;
    if (previous.$1 != principal) throw const SceneAccessDenied();
    host._entries[sessionId] = (principal, previous.$2, previous.$3, false);
  }
}

/// Call update after polling or reconnect. Local navigation must call stop.
/// A local timer ends following even when the network stops responding.
final class SharedCameraFollower {
  final void Function(Camera) apply;
  String? _session;
  Timer? _expiry;
  int _sequence = -1;
  bool _closed = false;
  String? get sessionId => _session;
  SharedCameraFollower({required this.apply});
  void follow(String sessionId) {
    if (_closed) throw StateError('Camera follower closed.');
    checkText(sessionId, 'sessionId');
    stop();
    _session = sessionId;
  }

  void update(List<ScenePresence> participants, {DateTime? now}) {
    if (_closed || _session == null) return;
    final matches = participants.where((p) => p.sessionId == _session);
    if (matches.isEmpty) {
      stop();
      return;
    }
    final person = matches.single;
    final remaining = person.expiresAt.difference(now ?? DateTime.now());
    if (remaining <= Duration.zero || person.camera == null) {
      stop();
      return;
    }
    if (person.sequence <= _sequence) return;
    final camera = person.camera!.createCamera();
    apply(camera);
    _sequence = person.sequence;
    _expiry?.cancel();
    _expiry = Timer(remaining, stop);
  }

  void stop() {
    _expiry?.cancel();
    _expiry = null;
    _session = null;
    _sequence = -1;
  }

  void close() {
    stop();
    _closed = true;
  }
}
