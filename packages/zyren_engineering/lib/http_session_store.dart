import 'dart:convert';
import 'dart:io';
import 'zyren_engineering.dart';

export 'zyren_engineering.dart' show EngineeringVersionConflict;

/// HTTP review endpoint: GET and PUT bounded schema-1 JSON with a strong ETag.
/// PUT must implement atomic If-Match and return the committed document and ETag.
/// Your host supplies authentication headers and owns the client lifecycle.
final class HttpEngineeringSessionStore implements EngineeringSessionStore {
  final HttpClient client;
  final Uri endpoint;
  final Future<Map<String, String>> Function() headers;
  HttpEngineeringSessionStore({
    required this.client,
    required this.endpoint,
    required this.headers,
  }) {
    if (endpoint.userInfo.isNotEmpty ||
        endpoint.fragment.isNotEmpty ||
        endpoint.host.isEmpty ||
        !(endpoint.scheme == 'https' ||
            endpoint.scheme == 'http' &&
                const {
                  '127.0.0.1',
                  '::1',
                  'localhost',
                }.contains(endpoint.host))) {
      throw ArgumentError('Use HTTPS or a loopback HTTP review endpoint.');
    }
  }

  @override
  Future<EngineeringRevision> read() => _request('GET');

  @override
  Future<EngineeringRevision> compareAndWrite({
    required String expectedVersion,
    required EngineeringDocument document,
  }) {
    _etag(expectedVersion);
    return _request(
      'PUT',
      version: expectedVersion,
      document: document.encode(),
    );
  }

  Future<EngineeringRevision> _request(
    String method, {
    String? version,
    String? document,
  }) async {
    final auth = await headers();
    final request = await client.openUrl(method, endpoint);
    request.followRedirects = false;
    try {
      auth.forEach(request.headers.set);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (version != null) {
        request.headers.set(HttpHeaders.ifMatchHeader, version);
      }
      if (document != null) {
        request.headers.contentType = ContentType.json;
        request.add(utf8.encode(document));
      }
      final response = await request.close();
      if (response.statusCode == 409 || response.statusCode == 412) {
        throw const EngineeringVersionConflict();
      }
      if (response.statusCode != 200) {
        throw HttpException(
          'Review service returned HTTP ${response.statusCode}.',
          uri: endpoint,
        );
      }
      final etag = response.headers.value(HttpHeaders.etagHeader);
      if (etag == null) {
        throw const FormatException('Review response has no ETag.');
      }
      _etag(etag);
      final bytes = <int>[];
      await for (final chunk in response) {
        if (bytes.length + chunk.length >
            EngineeringDocument.maxCharacters * 4) {
          throw const FormatException(
            'Review response exceeds the size limit.',
          );
        }
        bytes.addAll(chunk);
      }
      return EngineeringRevision(
        version: etag,
        document: EngineeringDocument.decode(utf8.decode(bytes)),
      );
    } catch (_) {
      request.abort();
      rethrow;
    }
  }
}

void _etag(String value) {
  if (value.length < 2 ||
      value.length > 256 ||
      !value.startsWith('"') ||
      !value.endsWith('"') ||
      value
          .substring(1, value.length - 1)
          .codeUnits
          .any((char) => char < 0x21 || char == 0x22 || char > 0x7e)) {
    throw const FormatException('Review requires a bounded strong ETag.');
  }
}
