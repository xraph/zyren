/// Opt-in loopback access to the GPU inspector attached to your host.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:zyren/zyren.dart';
import 'gpu_tools.dart';
import 'zyren_devtools.dart';

/// Attach explicitly. No listener starts when you import this library.
final class GpuInspectionBridge extends ScenePlugin {
  @override
  String get id => 'zyren.devtools.gpuBridge';
  @override
  Set<String> get dependencies => {'zyren.devtools'};
  HttpServer? _server;
  String? _token;
  bool _busy = false;
  Uri get endpoint {
    final server = _server;
    if (server == null) throw StateError('Bridge is not attached.');
    return Uri.parse('http://127.0.0.1:${server.port}/gpu');
  }

  String get sessionToken =>
      _token ?? (throw StateError('Bridge is not attached.'));

  @override
  Future<void> attach(PluginContext context) async {
    final tools = GpuInspectionTools(context.service(sceneDevtools));
    final random = Random.secure();
    final token = base64Url.encode(
      List.generate(32, (_) => random.nextInt(256)),
    );
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
      shared: false,
    );
    _token = token;
    _server = server;
    context.scope.onClose(() async {
      _server = null;
      _token = null;
      await server.close(force: true);
    });
    server.listen((request) => unawaited(_handle(request, tools)));
  }

  Future<void> _handle(HttpRequest request, GpuInspectionTools tools) async {
    final response = request.response;
    response.headers.contentType = ContentType.json;
    response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
    try {
      if (_token == null ||
          request.headers.value('origin') != null ||
          request.connectionInfo?.remoteAddress.address != '127.0.0.1' ||
          request.headers.value(HttpHeaders.authorizationHeader) !=
              'Bearer $_token') {
        response.statusCode = HttpStatus.forbidden;
        return;
      }
      if (request.method != 'POST' ||
          request.uri.path != '/gpu' ||
          request.uri.hasQuery) {
        response.statusCode = HttpStatus.notFound;
        return;
      }
      if (_busy) {
        response.statusCode = HttpStatus.tooManyRequests;
        return;
      }
      if (request.contentLength > 8192) {
        response.statusCode = HttpStatus.requestEntityTooLarge;
        return;
      }
      _busy = true;
      try {
        final bytes = <int>[];
        await for (final chunk in request.timeout(const Duration(seconds: 5))) {
          if (bytes.length + chunk.length > 8192) {
            response.statusCode = HttpStatus.requestEntityTooLarge;
            return;
          }
          bytes.addAll(chunk);
        }
        final arguments =
            jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        response.write(
          jsonEncode(await tools.call('zyren_gpu_inspect', arguments)),
        );
      } on ArgumentError {
        response.statusCode = HttpStatus.badRequest;
      } on FormatException {
        response.statusCode = HttpStatus.badRequest;
      } on TypeError {
        response.statusCode = HttpStatus.badRequest;
      } on TimeoutException {
        response.statusCode = HttpStatus.requestTimeout;
      } on StateError {
        response.statusCode = HttpStatus.serviceUnavailable;
      } finally {
        _busy = false;
      }
    } catch (_) {
      response.statusCode = HttpStatus.serviceUnavailable;
    } finally {
      try {
        await response.close();
      } catch (_) {
        /* Host may already be closed. */
      }
    }
  }
}

/// Queries a host bridge without creating a GPU device in this process.
final class GpuInspectionClient {
  final Uri endpoint;
  final String _sessionToken;
  final _http = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  bool _closed = false;
  GpuInspectionClient({required this.endpoint, required String sessionToken})
    : _sessionToken = sessionToken {
    if (endpoint.scheme != 'http' ||
        endpoint.host != '127.0.0.1' ||
        endpoint.path != '/gpu' ||
        endpoint.hasQuery ||
        endpoint.hasFragment ||
        endpoint.userInfo.isNotEmpty ||
        sessionToken.isEmpty) {
      throw ArgumentError(
        'Use the host bridge loopback endpoint and session token.',
      );
    }
  }
  Future<Map<String, dynamic>> inspectGpu({int allocationLimit = 128}) async {
    if (_closed) throw StateError('Inspection client has closed.');
    if (allocationLimit < 1 || allocationLimit > 256) {
      throw RangeError.range(allocationLimit, 1, 256);
    }
    _http.findProxy = (_) => 'DIRECT';
    final request = await _http.postUrl(endpoint);
    request.followRedirects = false;
    request.headers.contentType = ContentType.json;
    request.headers.set(
      HttpHeaders.authorizationHeader,
      'Bearer $_sessionToken',
    );
    request.write(jsonEncode({'allocationLimit': allocationLimit}));
    final response = await request.close().timeout(const Duration(seconds: 10));
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw StateError(
        'GPU inspection failed with HTTP ${response.statusCode}.',
      );
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 10))) {
      if (bytes.length + chunk.length > 256 * 1024) {
        _http.close(force: true);
        _closed = true;
        throw StateError('GPU inspection response exceeds 256 KiB.');
      }
      bytes.addAll(chunk);
    }
    return jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  }

  void close() {
    _closed = true;
    _http.close(force: true);
  }
}
