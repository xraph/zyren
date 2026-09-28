/// Optional local transport. Import explicitly in debug tooling hosts.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'zyren_devtools.dart';

export 'src/mcp.dart' show serveDevtoolsMcp;

const _requestLimit = 16 * 1024;
const _responseLimit = 8 * 1024 * 1024;
const _timeout = Duration(seconds: 5);

/// Authenticated, read-only loopback bridge for one scene diagnostics instance.
/// The owner must close this server when its debug session ends.
final class DevtoolsServer {
  final HttpServer _server;
  final SceneDiagnostics diagnostics;
  final String token;
  Future<void>? _closing;
  int _active = 0, _windowCount = 0;
  final _window = Stopwatch()..start();
  DevtoolsServer._(this._server, this.diagnostics, this.token) {
    _server.idleTimeout = _timeout;
    _server.listen(_handle);
  }
  Uri get endpoint => Uri.parse('http://127.0.0.1:${_server.port}/call');
  static Future<DevtoolsServer> start(
    SceneDiagnostics diagnostics, {
    int port = 0,
  }) async {
    final random = Random.secure();
    final token = base64UrlEncode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, port);
    return DevtoolsServer._(server, diagnostics, token);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    _active++;
    void fail(int status, String code, String message) {
      response.statusCode = status;
      response.write(
        jsonEncode({
          'error': {'code': code, 'message': message},
        }),
      );
    }

    try {
      if (request.headers.value('origin') != null ||
          request.headers.value('host') != '127.0.0.1:${_server.port}') {
        fail(
          403,
          'forbiddenOrigin',
          'Only direct loopback clients are supported.',
        );
      } else if (request.headers.value('authorization') != 'Bearer $token') {
        fail(401, 'unauthorized', 'Provide the current debug session token.');
      } else if (request.method != 'POST' ||
          request.uri.path != '/call' ||
          request.uri.hasQuery) {
        fail(404, 'notFound', 'Use POST /call.');
      } else {
        if (_window.elapsedMilliseconds >= 1000) {
          _window.reset();
          _windowCount = 0;
        }
        if (_active > 4 || ++_windowCount > 30) {
          fail(429, 'rateLimited', 'Wait before requesting more diagnostics.');
        } else {
          final bytes = await _readBounded(
            request,
            _requestLimit,
          ).timeout(_timeout);
          final input = jsonDecode(utf8.decode(bytes));
          if (input is! Map<String, dynamic> ||
              input['name'] is! String ||
              input.keys.any((k) => k != 'name' && k != 'arguments') ||
              input.containsKey('arguments') &&
                  input['arguments'] is! Map<String, dynamic>) {
            throw const DiagnosticException(
              'invalidRequest',
              'Expected name and an optional arguments object.',
            );
          }
          final result = diagnostics.call(
            input['name'] as String,
            (input['arguments'] as Map<String, dynamic>?) ?? const {},
          );
          final encoded = utf8.encode(jsonEncode(result));
          if (encoded.length > _responseLimit) {
            throw const DiagnosticException(
              'responseTooLarge',
              'Use a smaller inspection page.',
            );
          }
          response.add(encoded);
        }
      }
    } on DiagnosticException catch (error) {
      fail(
        error.code == 'payloadTooLarge' ? 413 : 400,
        error.code,
        error.message,
      );
    } on FormatException {
      fail(400, 'invalidJson', 'Request must contain UTF-8 JSON.');
    } on TimeoutException {
      fail(408, 'requestTimeout', 'Request body timed out.');
    } catch (_) {
      fail(
        500,
        'inspectionFailed',
        'Inspection failed. Check the host scene and issue stream.',
      );
    } finally {
      _active--;
      try {
        await response.close();
      } on IOException {
        /* Client disconnected. */
      }
    }
  }

  Future<void> close() => _closing ??= _server.close(force: true).then((_) {});
}

/// Explicit loopback client. Never follows redirects or sends tokens via a proxy.
final class DevtoolsClient {
  final Uri endpoint;
  final String token;
  final HttpClient _http = HttpClient();
  DevtoolsClient({required this.endpoint, required this.token}) {
    if (endpoint.scheme != 'http' ||
        endpoint.host != '127.0.0.1' ||
        endpoint.port < 1 ||
        endpoint.userInfo.isNotEmpty ||
        endpoint.path != '/call' ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        token.isEmpty ||
        token.contains('\n') ||
        token.contains('\r')) {
      _http.close(force: true);
      throw ArgumentError(
        'Use the loopback /call endpoint and token from your debug session.',
      );
    }
    _http.connectionTimeout = _timeout;
    _http.findProxy = (_) => 'DIRECT';
  }
  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> arguments = const {},
  ]) async {
    HttpClientRequest? request;
    try {
      return await (() async {
        final encoded = utf8.encode(
          jsonEncode({'name': name, 'arguments': arguments}),
        );
        if (encoded.length > _requestLimit) {
          throw const DiagnosticException(
            'payloadTooLarge',
            'Tool arguments exceed 16 KiB.',
          );
        }
        final outgoing = await _http.postUrl(endpoint);
        request = outgoing;
        outgoing.followRedirects = false;
        outgoing.headers.contentType = ContentType.json;
        outgoing.headers.set('authorization', 'Bearer $token');
        outgoing.add(encoded);
        final response = await outgoing.close();
        final bytes = await _readBounded(response, _responseLimit);
        final result = jsonDecode(utf8.decode(bytes));
        if (result is! Map<String, dynamic>) {
          throw const FormatException('Expected an object.');
        }
        if (response.statusCode != 200) {
          final error = result['error'];
          if (error is Map &&
              error['code'] is String &&
              error['message'] is String) {
            throw DiagnosticException(
              error['code'] as String,
              error['message'] as String,
            );
          }
          throw const DiagnosticException(
            'connectionFailed',
            'Bridge rejected the request.',
          );
        }
        if (result['schemaVersion'] != SceneDiagnostics.schemaVersion) {
          throw const DiagnosticException(
            'schemaMismatch',
            'The scene bridge uses an unsupported schema version.',
          );
        }
        return result;
      })().timeout(_timeout);
    } on TimeoutException {
      request?.abort();
      throw const DiagnosticException(
        'connectionTimeout',
        'The debug bridge did not respond within five seconds.',
      );
    } on IOException {
      throw const DiagnosticException(
        'connectionFailed',
        'Cannot reach the debug bridge. Check the endpoint and running application.',
      );
    } on FormatException {
      throw const DiagnosticException(
        'invalidResponse',
        'The debug bridge returned invalid JSON.',
      );
    }
  }

  void close() => _http.close(force: true);
}

Future<List<int>> _readBounded(Stream<List<int>> source, int limit) async {
  final result = <int>[];
  await for (final chunk in source) {
    if (result.length + chunk.length > limit) {
      throw const DiagnosticException(
        'payloadTooLarge',
        'Payload exceeds the transport budget.',
      );
    }
    result.addAll(chunk);
  }
  return result;
}
