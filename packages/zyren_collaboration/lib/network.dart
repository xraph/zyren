/// Native HTTP and WebSocket transports. The host owns TLS and authentication.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'zyren_collaboration.dart';
import 'src/model.dart' show objectMap, textValue, revisionValue;

const _wireLimit = 20 * 1024 * 1024;
void _endpoint(Uri uri) {
  final loopback =
      uri.host == 'localhost' ||
      InternetAddress.tryParse(uri.host)?.isLoopback == true;
  if (!['https', 'wss', 'http', 'ws'].contains(uri.scheme) ||
      (!['https', 'wss'].contains(uri.scheme) && !loopback) ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw ArgumentError(
      'Use TLS outside loopback and supply credentials through headers.',
    );
  }
}

Future<String> _body(Stream<List<int>> stream) async {
  final bytes = <int>[];
  await for (final chunk in stream) {
    if (bytes.length + chunk.length > _wireLimit) {
      throw const FormatException('Scene response exceeds limit.');
    }
    bytes.addAll(chunk);
  }
  return utf8.decode(bytes);
}

Map<String, Object?> encodeSceneResult(SceneOperationResult result) => {
  'operation': result.operation.encode(),
  'snapshot': result.snapshot.encode(),
  'accepted': result is SceneOperationAccepted,
  if (result is SceneOperationAccepted) 'revision': result.committedRevision,
  if (result is SceneOperationAccepted) 'duplicate': result.duplicate,
};
SceneOperationResult decodeSceneResult(Object? value) {
  final j = objectMap(value);
  final op = SceneOperation.decode(textValue(j['operation']));
  final snapshot = SceneSnapshot.decode(textValue(j['snapshot']));
  if (j['accepted'] == false) {
    return SceneOperationConflict(operation: op, snapshot: snapshot);
  }
  if (j['accepted'] != true || j['duplicate'] is! bool) {
    throw const FormatException('Invalid scene receipt.');
  }
  return SceneOperationAccepted(
    operation: op,
    snapshot: snapshot,
    committedRevision: revisionValue(j['revision']),
    duplicate: j['duplicate'] as bool,
  );
}

/// One server owns a scene epoch. Authenticate every request, including messages
/// on established sockets, so revoked credentials stop working immediately.
final class SceneCollaborationServer {
  final HttpServer _server;
  final String sceneId, epoch;
  final FutureOr<String?> Function(HttpRequest request) authenticate;
  final SceneOperationTransport Function(String principal) connect;
  final ScenePresenceAuthority? presence;
  final Duration timeout;
  final int maxSockets;
  final _sockets = <WebSocket>{};
  final _subscriptions = <StreamSubscription<dynamic>>{};
  final _dirty = <WebSocket>{};
  Timer? _notification;
  bool _closed = false;
  SceneCollaborationServer._(
    this._server,
    this.sceneId,
    this.epoch,
    this.authenticate,
    this.connect,
    this.presence,
    this.timeout,
    this.maxSockets,
  );
  Uri get endpoint => Uri(
    scheme: _secure ? 'https' : 'http',
    host: _server.address.address,
    port: _server.port,
    path: '/scene',
  );
  bool _secure = false;
  static Future<SceneCollaborationServer> bind({
    required String sceneId,
    required String epoch,
    required FutureOr<String?> Function(HttpRequest request) authenticate,
    required SceneOperationTransport Function(String principal) connect,
    ScenePresenceAuthority? presence,
    InternetAddress? address,
    int port = 0,
    SecurityContext? securityContext,
    Duration timeout = const Duration(seconds: 10),
    int maxSockets = 100,
  }) async {
    final host = address ?? InternetAddress.loopbackIPv4;
    if (!host.isLoopback && securityContext == null) {
      throw ArgumentError('Remote hosts require TLS.');
    }
    if (maxSockets < 1 || maxSockets > 1000 || timeout <= Duration.zero) {
      throw ArgumentError('Invalid server limits.');
    }
    final http = securityContext == null
        ? await HttpServer.bind(host, port)
        : await HttpServer.bindSecure(host, port, securityContext);
    final result = SceneCollaborationServer._(
      http,
      sceneId,
      epoch,
      authenticate,
      connect,
      presence,
      timeout,
      maxSockets,
    ).._secure = securityContext != null;
    // Failed TLS handshakes have no authenticated request to dispatch.
    http.listen(result._serve, onError: (Object error, StackTrace stack) {});
    return result;
  }

  Future<void> _serve(HttpRequest request) async {
    try {
      if (_closed || request.uri.path != '/scene') {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      if (WebSocketTransformer.isUpgradeRequest(request)) {
        final principal = await Future<String?>.sync(
          () => authenticate(request),
        ).timeout(timeout);
        if (principal == null || _sockets.length >= maxSockets) {
          request.response.statusCode = 403;
          await request.response.close();
          return;
        }
        final socket = await WebSocketTransformer.upgrade(request);
        socket.pingInterval = const Duration(seconds: 15);
        _sockets.add(socket);
        var pending = 0;
        var tail = Future<void>.value();
        late StreamSubscription<dynamic> subscription;
        subscription = socket.listen(
          (message) {
            if (message is! String ||
                message.length > _wireLimit ||
                ++pending > 16) {
              unawaited(socket.close(1009, 'Message limit'));
              return;
            }
            tail = tail
                .then((_) async {
                  try {
                    final answer = await _dispatch(request, message);
                    if (socket.readyState == WebSocket.open) {
                      socket.add(jsonEncode(answer));
                    }
                  } finally {
                    pending--;
                  }
                })
                .catchError((Object _) {
                  unawaited(socket.close(1011, 'Request failed'));
                });
          },
          onDone: () {
            _sockets.remove(socket);
            _dirty.remove(socket);
            _subscriptions.remove(subscription);
          },
          onError: (Object _) {
            _sockets.remove(socket);
            _dirty.remove(socket);
          },
        );
        _subscriptions.add(subscription);
        return;
      }
      if (request.method != 'POST') {
        request.response.statusCode = 405;
        await request.response.close();
        return;
      }
      final message = await _body(request).timeout(timeout);
      final answer = await _dispatch(request, message);
      request.response.headers.contentType = ContentType.json;
      request.response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
      request.response.write(jsonEncode(answer));
      await request.response.close();
    } catch (_) {
      try {
        request.response.statusCode = 400;
        await request.response.close();
      } catch (_) {}
    }
  }

  Future<Map<String, Object?>> _dispatch(
    HttpRequest request,
    String message,
  ) async {
    Object? requestId;
    try {
      final j = objectMap(jsonDecode(message));
      requestId = j['id'];
      if (requestId is! int || j['schemaVersion'] != 1) {
        throw const FormatException('Invalid request envelope.');
      }
      final principal = await Future<String?>.sync(
        () => authenticate(request),
      ).timeout(timeout);
      if (principal == null) throw const SceneAccessDenied();
      final transport = connect(principal);
      final current = await transport.read();
      if (j['sceneId'] != sceneId ||
          j['epoch'] != epoch ||
          current.sceneId != sceneId ||
          current.epoch != epoch) {
        throw const SceneSessionMismatch();
      }
      final args = objectMap(j['args']);
      final method = textValue(j['method']);
      final Object? value;
      switch (method) {
        case 'read':
          value = current.encode();
        case 'submit':
          value = encodeSceneResult(
            await transport.submit(
              SceneOperation.decode(textValue(args['operation'])),
            ),
          );
        case 'prepare_undo':
          if (transport is! SceneUndoTransport) {
            throw UnsupportedError('Undo unavailable.');
          }
          value = (await (transport as SceneUndoTransport).prepareUndo(
            revision: revisionValue(args['revision']),
            operationId: textValue(args['operationId']),
          )).encode();
        case 'undo':
          if (transport is! SceneUndoTransport) {
            throw UnsupportedError('Undo unavailable.');
          }
          value = encodeSceneResult(
            await (transport as SceneUndoTransport).undo(
              revision: revisionValue(args['revision']),
              operationId: textValue(args['operationId']),
            ),
          );
        case 'allows':
          if (transport is! SceneCollaborationQueries) {
            throw UnsupportedError('Queries unavailable.');
          }
          value = await (transport as SceneCollaborationQueries).allows(
            SceneOperation.decode(textValue(args['operation'])),
          );
        case 'history':
          if (transport is! SceneCollaborationQueries) {
            throw UnsupportedError('Queries unavailable.');
          }
          final page = await (transport as SceneCollaborationQueries).history(
            expectedRevision: revisionValue(args['revision']),
            afterRevision: revisionValue(args['after']),
            limit: args['limit'] as int,
          );
          value = {
            'revision': page.sceneRevision,
            'next': page.nextAfterRevision,
            'records': [
              for (final r in page.records)
                {'operation': r.operation.encode(), 'revision': r.revision},
            ],
          };
        case 'participants':
          if (presence == null) throw UnsupportedError('Presence unavailable.');
          value = (await presence!.connect(principal).participants())
              .map((p) => p.toJson())
              .toList();
        case 'presence':
          if (presence == null) throw UnsupportedError('Presence unavailable.');
          await presence!
              .connect(principal)
              .publishPresence(
                sessionId: textValue(args['sessionId']),
                label: textValue(args['label']),
                sequence: revisionValue(args['sequence']),
                camera: args['camera'] == null
                    ? null
                    : SharedSceneCamera.fromJson(args['camera']),
                selection: args['selection'] == null
                    ? null
                    : SceneObjectId.fromJson(args['selection']),
              );
          value = null;
        case 'leave':
          if (presence == null) throw UnsupportedError('Presence unavailable.');
          await presence!
              .connect(principal)
              .leave(textValue(args['sessionId']));
          value = null;
        default:
          throw UnsupportedError('Unknown scene method.');
      }
      if (['submit', 'undo', 'presence', 'leave'].contains(method)) _notify();
      return {'id': requestId, 'value': value};
    } catch (error) {
      final code = switch (error) {
        SceneAccessDenied() => 'denied',
        SceneSessionMismatch() => 'epoch',
        SceneRevisionMismatch() => 'stale',
        SceneReceiptCapacityExceeded() => 'capacity',
        UnsupportedError() => 'unsupported',
        TimeoutException() => 'timeout',
        _ => 'invalid',
      };
      return {'id': requestId, 'error': code};
    }
  }

  void _notify() {
    // Invalidation contains no scene data. Readers reauthenticate before fetching.
    _dirty.addAll(_sockets);
    _notification ??= Timer(const Duration(milliseconds: 50), () {
      for (final socket in _dirty) {
        if (socket.readyState == WebSocket.open) {
          socket.add('{"event":"changed"}');
        }
      }
      _dirty.clear();
      _notification = null;
    });
  }

  Future<void> close() async {
    _closed = true;
    _notification?.cancel();
    await Future.wait(
      _sockets.toList().map((s) => s.close(1001, 'Host closed')),
    );
    for (final s in _subscriptions.toList()) {
      await s.cancel();
    }
    await _server.close(force: true);
  }
}

abstract class NetworkSceneTransport
    implements
        SceneOperationTransport,
        SceneUndoTransport,
        SceneCollaborationQueries,
        ScenePresenceTransport {
  final String sceneId, epoch;
  int _next = 0;
  NetworkSceneTransport({required this.sceneId, required this.epoch});
  Future<Object?> request(Map<String, Object?> message);
  Future<Object?> _call(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    final id = ++_next;
    final answer = objectMap(
      await request({
        'schemaVersion': 1,
        'id': id,
        'sceneId': sceneId,
        'epoch': epoch,
        'method': method,
        'args': args,
      }),
    );
    if (answer['id'] != id) throw const FormatException('Mismatched response.');
    if (answer.containsKey('error')) {
      throw switch (answer['error']) {
        'denied' => const SceneAccessDenied(),
        'epoch' => const SceneSessionMismatch(),
        'stale' => const SceneRevisionMismatch(),
        'capacity' => const SceneReceiptCapacityExceeded(),
        'unsupported' => UnsupportedError('Scene service unavailable.'),
        'timeout' => TimeoutException('Scene service timed out.'),
        _ => StateError('Scene service rejected request.'),
      };
    }
    return answer['value'];
  }

  @override
  Future<SceneSnapshot> read() async =>
      SceneSnapshot.decode(textValue(await _call('read')));
  @override
  Future<SceneOperationResult> submit(SceneOperation op) async =>
      decodeSceneResult(await _call('submit', {'operation': op.encode()}));
  @override
  Future<SceneOperation> prepareUndo({
    required int revision,
    required String operationId,
  }) async => SceneOperation.decode(
    textValue(
      await _call('prepare_undo', {
        'revision': revision,
        'operationId': operationId,
      }),
    ),
  );
  @override
  Future<SceneOperationResult> undo({
    required int revision,
    required String operationId,
  }) async => decodeSceneResult(
    await _call('undo', {'revision': revision, 'operationId': operationId}),
  );
  @override
  Future<bool> allows(SceneOperation op) async =>
      await _call('allows', {'operation': op.encode()}) as bool;
  @override
  Future<SceneHistoryPage> history({
    required int expectedRevision,
    int afterRevision = 0,
    int limit = 50,
  }) async {
    final j = objectMap(
      await _call('history', {
        'revision': expectedRevision,
        'after': afterRevision,
        'limit': limit,
      }),
    );
    return SceneHistoryPage(
      sceneRevision: revisionValue(j['revision']),
      nextAfterRevision: j['next'] as int?,
      records: (j['records'] as List).map((r) {
        final row = objectMap(r);
        return SceneOperationRecord(
          SceneOperation.decode(textValue(row['operation'])),
          revisionValue(row['revision']),
        );
      }),
    );
  }

  @override
  Future<List<ScenePresence>> participants() async => List.unmodifiable(
    (await _call('participants') as List).map(ScenePresence.fromJson),
  );
  @override
  Future<void> publishPresence({
    required String sessionId,
    required String label,
    required int sequence,
    SharedSceneCamera? camera,
    SceneObjectId? selection,
  }) async {
    await _call('presence', {
      'sessionId': sessionId,
      'label': label,
      'sequence': sequence,
      if (camera != null) 'camera': camera.toJson(),
      if (selection != null) 'selection': selection.toJson(),
    });
  }

  @override
  Future<void> leave(String sessionId) async {
    await _call('leave', {'sessionId': sessionId});
  }

  Future<void> close();
}

final class HttpSceneTransport extends NetworkSceneTransport {
  final Uri endpoint;
  final FutureOr<Map<String, String>> Function() headers;
  final Duration timeout;
  final HttpClient _client;
  bool _closed = false;
  HttpSceneTransport({
    required this.endpoint,
    required super.sceneId,
    required super.epoch,
    required this.headers,
    this.timeout = const Duration(seconds: 10),
    HttpClient? client,
  }) : _client = client ?? HttpClient() {
    _endpoint(endpoint);
    if (!['http', 'https'].contains(endpoint.scheme) ||
        timeout <= Duration.zero) {
      throw ArgumentError('Invalid HTTP options.');
    }
    _client.connectionTimeout = timeout;
  }
  @override
  Future<Object?> request(Map<String, Object?> message) async {
    if (_closed) throw StateError('Transport closed.');
    HttpClientRequest? active;
    var expired = false;
    return (() async {
      final auth = await headers();
      if (expired || _closed) {
        throw StateError('Request cancelled before dispatch.');
      }
      final request = active = await _client.postUrl(endpoint);
      if (expired || _closed) {
        request.abort();
        throw StateError('Request cancelled before dispatch.');
      }
      request.followRedirects = false;
      auth.forEach(request.headers.set);
      request.headers.contentType = ContentType.json;
      request.write(jsonEncode(message));
      final response = await request.close();
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException('Scene HTTP ${response.statusCode}');
      }
      return jsonDecode(await _body(response));
    })().timeout(
      timeout,
      onTimeout: () {
        expired = true;
        active?.abort();
        throw TimeoutException(
          'Scene request timed out; retry the same operation.',
        );
      },
    );
  }

  @override
  Future<void> close() async {
    _closed = true;
    _client.close(force: true);
  }
}

/// Bounded multiplexed RPC with coalesced invalidations. A broken connection
/// rejects in-flight calls; the next call reconnects with fresh host credentials.
/// Retry writes only through their exact operation ID or persistent outbox.
final class WebSocketSceneTransport extends NetworkSceneTransport {
  final Uri endpoint;
  final FutureOr<Map<String, String>> Function() headers;
  final Duration timeout;
  final HttpClient? httpClient;
  WebSocket? _socket;
  Future<WebSocket>? _connecting;
  final _pending = <int, Completer<Object?>>{};
  final _changes = StreamController<void>.broadcast();
  Stream<void> get changes => _changes.stream;
  bool _closed = false;
  WebSocketSceneTransport({
    required this.endpoint,
    required super.sceneId,
    required super.epoch,
    required this.headers,
    this.timeout = const Duration(seconds: 10),
    this.httpClient,
  }) {
    _endpoint(endpoint);
    if (!['ws', 'wss'].contains(endpoint.scheme) || timeout <= Duration.zero) {
      throw ArgumentError('Invalid WebSocket options.');
    }
  }
  Future<WebSocket> _open() async {
    if (_closed) throw StateError('Transport closed.');
    if (_socket case final socket?) {
      if (socket.readyState == WebSocket.open) return socket;
    }
    return _connecting ??= _connect().whenComplete(() => _connecting = null);
  }

  Future<WebSocket> _connect() async {
    final auth = await Future<Map<String, String>>.sync(
      headers,
    ).timeout(timeout);
    if (_closed) throw StateError('Transport closed.');
    final opening = WebSocket.connect(
      endpoint.toString(),
      headers: auth,
      customClient: httpClient,
    );
    final WebSocket socket;
    try {
      socket = await opening.timeout(timeout);
    } catch (_) {
      unawaited(
        opening.then((late) async {
          await late.close();
        }, onError: (Object _) {}),
      );
      rethrow;
    }
    if (_closed) {
      await socket.close();
      throw StateError('Transport closed.');
    }
    _socket = socket;
    socket.pingInterval = const Duration(seconds: 15);
    socket.listen(
      (message) {
        try {
          if (message is! String || message.length > _wireLimit) {
            throw const FormatException('Invalid scene message.');
          }
          final answer = objectMap(jsonDecode(message));
          if (answer['event'] == 'changed') {
            _changes.add(null);
            return;
          }
          _pending.remove(answer['id'])?.complete(answer);
        } catch (e, st) {
          _fail(e, st);
          unawaited(socket.close(1002));
        }
      },
      onDone: () {
        if (identical(_socket, socket)) {
          _socket = null;
          _fail(const SocketException('Scene connection closed.'));
        }
      },
      onError: (Object e, StackTrace st) {
        if (identical(_socket, socket)) _fail(e, st);
      },
    );
    _changes.add(null);
    return socket;
  }

  void _fail(Object error, [StackTrace? stack]) {
    for (final c in _pending.values) {
      c.completeError(error, stack);
    }
    _pending.clear();
  }

  @override
  Future<Object?> request(Map<String, Object?> message) async {
    final socket = await _open();
    if (_pending.length >= 16) throw StateError('Too many scene requests.');
    final id = message['id'] as int, done = Completer<Object?>();
    _pending[id] = done;
    socket.add(jsonEncode(message));
    try {
      return await done.future.timeout(timeout);
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _fail(StateError('Transport closed.'));
    await _socket?.close();
    await _changes.close();
  }
}
