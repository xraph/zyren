import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_engineering/http_session_store.dart';

void main() {
  late HttpServer server;
  late HttpClient client;
  late HttpEngineeringSessionStore store;
  late EngineeringDocument document;
  var version = '"v0"';
  var status = 200;
  var token = 'session-token';
  var requests = 0;
  setUp(() async {
    version = '"v0"';
    status = 200;
    token = 'session-token';
    requests = 0;
    document = EngineeringDocument(id: 'review');
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
    store = HttpEngineeringSessionStore(
      client: client,
      endpoint: Uri.parse('http://127.0.0.1:${server.port}/review'),
      headers: () async => {'Authorization': 'Bearer $token'},
    );
    server.listen((request) async {
      requests++;
      final response = request.response;
      if (request.headers.value('Authorization') != 'Bearer session-token') {
        response.statusCode = 403;
      } else if (status != 200) {
        response.statusCode = status;
      } else if (request.method == 'PUT' &&
          request.headers.value(HttpHeaders.ifMatchHeader) != version) {
        response.statusCode = 412;
      } else {
        if (request.method == 'PUT') {
          document = EngineeringDocument.decode(
            await utf8.decoder.bind(request).join(),
          );
          version = '"v1"';
        }
        response.headers.set(HttpHeaders.etagHeader, version);
        response.write(document.encode());
      }
      await response.close();
    });
  });
  tearDown(() async {
    client.close(force: true);
    await server.close(force: true);
  });

  test('authenticated GET and conditional PUT use service revisions', () async {
    final base = await store.read();
    final next = EngineeringDocument(
      id: 'review',
      objects: [EngineeringObject(id: 'source-key', label: 'Housing')],
    );
    final committed = await store.compareAndWrite(
      expectedVersion: base.version,
      document: next,
    );
    expect(committed.version, '"v1"');
    expect(committed.document.objects.keys, ['source-key']);
    expect((await store.read()).document.encode(), next.encode());
    await expectLater(
      store.compareAndWrite(expectedVersion: base.version, document: next),
      throwsA(isA<EngineeringVersionConflict>()),
    );
    expect(document.encode(), next.encode());
  });

  test(
    'denied access and service failures surface without rewriting data',
    () async {
      token = 'expired';
      await expectLater(store.read(), throwsA(isA<HttpException>()));
      token = 'session-token';
      status = 503;
      await expectLater(store.read(), throwsA(isA<HttpException>()));
      expect(document.objects, isEmpty);
    },
  );

  test('redirects and weak revisions are rejected', () async {
    status = 302;
    await expectLater(store.read(), throwsA(isA<HttpException>()));
    expect(requests, 1);
    status = 200;
    version = 'W/"v1"';
    await expectLater(store.read(), throwsFormatException);
    expect(
      () => store.compareAndWrite(
        expectedVersion: 'bad\r\nheader',
        document: document,
      ),
      throwsFormatException,
    );
  });

  test('remote cleartext and embedded credentials are rejected', () {
    for (final uri in [
      'http://example.com/review',
      'https://user:pass@example.com/review',
    ]) {
      expect(
        () => HttpEngineeringSessionStore(
          client: client,
          endpoint: Uri.parse(uri),
          headers: () async => {},
        ),
        throwsArgumentError,
      );
    }
  });
}
