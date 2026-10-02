import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'zyren_engineering.dart';

/// Authorization belongs to the host, with separate read and write decisions.
/// The server exposes one configured document at /review and binds loopback only.
final class EngineeringReviewServer {
  final HttpServer _server;
  final EngineeringSessionStore _store;
  final Future<bool> Function(HttpRequest request, bool write) _authorize;
  final Duration bodyTimeout;
  EngineeringReviewServer._(
    this._server,
    this._store,
    this._authorize,
    this.bodyTimeout,
  ) {
    _server.listen(_handle);
  }

  static Future<EngineeringReviewServer> start({
    required EngineeringSessionStore store,
    required Future<bool> Function(HttpRequest request, bool write) authorize,
    int port = 0,
    Duration bodyTimeout = const Duration(seconds: 10),
  }) async {
    if (bodyTimeout <= Duration.zero) {
      throw ArgumentError('Body timeout must be positive.');
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    return EngineeringReviewServer._(server, store, authorize, bodyTimeout);
  }

  Uri get endpoint => Uri.parse('http://127.0.0.1:${_server.port}/review');
  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    StreamSubscription<List<int>>? body;
    Timer? deadline;
    try {
      if (request.uri.path != '/review' || request.uri.hasQuery) {
        response.statusCode = 404;
        return;
      }
      final write = request.method == 'PUT';
      if (!write && request.method != 'GET') {
        response.headers.set(HttpHeaders.allowHeader, 'GET, PUT');
        response.statusCode = 405;
        return;
      }
      if (!await _authorize(request, write)) {
        response.statusCode = 403;
        return;
      }
      EngineeringRevision revision;
      if (write) {
        final expected = request.headers.value(HttpHeaders.ifMatchHeader);
        if (expected == null) {
          response.statusCode = 428;
          return;
        }
        if (!RegExp(r'^"[\x21\x23-\x7e]*"$').hasMatch(expected) ||
            expected.length > 256) {
          response.statusCode = 400;
          return;
        }
        if (request.headers.contentType?.mimeType != 'application/json') {
          response.statusCode = 415;
          return;
        }
        final limit = EngineeringDocument.maxCharacters * 4;
        if (request.contentLength > limit) {
          response.statusCode = 413;
          return;
        }
        final bytes = <int>[];
        final received = Completer<List<int>>();
        deadline = Timer(bodyTimeout, () {
          if (!received.isCompleted) {
            received.completeError(
              TimeoutException('Review body deadline exceeded.'),
            );
          }
        });
        body = request.listen(
          (chunk) {
            if (received.isCompleted) return;
            if (bytes.length + chunk.length > limit) {
              received.completeError(const _BodyTooLarge());
            } else {
              bytes.addAll(chunk);
            }
          },
          onError: (Object error, StackTrace stack) {
            if (!received.isCompleted) received.completeError(error, stack);
          },
          onDone: () {
            if (!received.isCompleted) received.complete(bytes);
          },
        );
        final document = EngineeringDocument.decode(
          utf8.decode(await received.future),
        );
        deadline.cancel();
        revision = await _store.compareAndWrite(
          expectedVersion: expected,
          document: document,
        );
      } else {
        revision = await _store.read();
      }
      response.headers.contentType = ContentType.json;
      response.headers.set(HttpHeaders.etagHeader, revision.version);
      response.write(revision.document.encode());
    } on EngineeringVersionConflict {
      response.statusCode = 412;
    } on FormatException {
      response.statusCode = 400;
    } on TimeoutException {
      response.statusCode = 408;
    } on _BodyTooLarge {
      response.statusCode = 413;
    } catch (_) {
      response.statusCode = 500;
    } finally {
      try {
        if (request.connectionInfo == null) {
          // The peer has already closed the transport.
        } else if (response.statusCode >= 400) {
          // Normal response close drains unread input first. Detach an error
          // response so a denied or oversized body cannot delay its rejection.
          response.contentLength = 0;
          response.persistentConnection = false;
          final socket = await response.detachSocket();
          try {
            await socket.flush();
            await socket.close();
          } finally {
            socket.destroy();
          }
        } else {
          await response.close();
        }
      } on IOException {
        // A disconnected client cannot receive the result.
      } finally {
        deadline?.cancel();
        await body?.cancel();
      }
    }
  }
}

final class _BodyTooLarge implements Exception {
  const _BodyTooLarge();
}
