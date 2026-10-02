import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_engineering/file_session_store.dart';
import 'package:zyren_engineering/http_session_store.dart';
import 'package:zyren_engineering/review_server.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import '../../zyren/test/support/fakes.dart';

EngineeringDocument seed() => EngineeringDocument(
  id: 'review',
  objects: [
    EngineeringObject(id: 'a', label: 'Housing'),
    EngineeringObject(id: 'b', label: 'Cover'),
  ],
);

void main() {
  late Directory temp;
  late FileEngineeringSessionStore repository;
  late EngineeringReviewServer server;
  late HttpClient client;
  late HttpEngineeringSessionStore session;
  var token = 'writer';
  var authFails = false;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('engineering-server-test-');
    repository = FileEngineeringSessionStore(
      file: File('${temp.path}/session.json'),
      documentId: 'review',
    );
    await repository.initialize(seed());
    token = 'writer';
    authFails = false;
    server = await EngineeringReviewServer.start(
      store: repository,
      authorize: (request, write) async {
        if (authFails) throw StateError('Host session unavailable');
        final auth = request.headers.value(HttpHeaders.authorizationHeader);
        return auth == 'Bearer writer' || !write && auth == 'Bearer reader';
      },
    );
    client = HttpClient();
    session = HttpEngineeringSessionStore(
      client: client,
      endpoint: server.endpoint,
      headers: () async => {'Authorization': 'Bearer $token'},
    );
  });
  tearDown(() async {
    client.close(force: true);
    await server.close();
    await temp.delete(recursive: true);
  });

  Future<int> request(
    String method, {
    String? body,
    String? version,
    String? path,
    String contentType = 'application/json',
  }) async {
    final req = await client.openUrl(
      method,
      path == null ? server.endpoint : server.endpoint.resolve(path),
    );
    req.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    req.headers.set(HttpHeaders.contentTypeHeader, contentType);
    if (version != null) req.headers.set(HttpHeaders.ifMatchHeader, version);
    if (body != null) req.add(utf8.encode(body));
    final response = await req.close();
    await response.drain<void>();
    return response.statusCode;
  }

  test(
    'two plugins merge, resolve competing edits and persist across restart',
    () async {
      final left = SceneEngineeringPlugin(document: seed());
      final right = SceneEngineeringPlugin(document: seed());
      Future<SceneEngine> engine(SceneEngineeringPlugin review) =>
          SceneEngine.create(
            scene: Scene(),
            camera: PerspectiveCamera(),
            rendererFactory: () async => TestRenderer([]),
            plugins: [review],
          );
      final leftEngine = await engine(left), rightEngine = await engine(right);
      addTearDown(() async {
        await leftEngine.dispose();
        await rightEngine.dispose();
      });
      var leftBase = await session.read(), rightBase = await session.read();
      left.putAnnotation(
        EngineeringAnnotation(
          id: 'left-note',
          objectId: 'a',
          text: 'Inspect seal',
          anchor: const Vec3(0, 0, 0),
        ),
      );
      right.putAnnotation(
        EngineeringAnnotation(
          id: 'right-note',
          objectId: 'b',
          text: 'Inspect cover',
          anchor: const Vec3(1, 0, 0),
        ),
      );
      leftBase = (await left.synchronize(session, base: leftBase)).revision;
      rightBase = (await right.synchronize(session, base: rightBase)).revision;
      expect(
        right.document.annotations.keys,
        containsAll(['left-note', 'right-note']),
      );
      left.putObject(EngineeringObject(id: 'a', label: 'Left edit'));
      right.putObject(EngineeringObject(id: 'a', label: 'Right edit'));
      leftBase = (await left.synchronize(session, base: leftBase)).revision;
      final conflict = await right.synchronize(session, base: rightBase);
      expect(conflict.written, isFalse);
      expect(right.document.objects['a']!.label, 'Right edit');
      expect(right.hasUnsavedChanges, isTrue);
      final resolved = await right.synchronize(
        session,
        base: rightBase,
        resolutions: [
          EngineeringConflictResolution(
            conflict.conflicts.single,
            EngineeringConflictChoice.local,
          ),
        ],
      );
      expect(resolved.written, isTrue);
      expect(right.hasUnsavedChanges, isFalse);
      final oldEndpoint = server.endpoint;
      await server.close();
      server = await EngineeringReviewServer.start(
        store: FileEngineeringSessionStore(
          file: repository.file,
          documentId: 'review',
        ),
        authorize: (request, write) async =>
            request.headers.value(HttpHeaders.authorizationHeader) ==
            'Bearer writer',
        port: oldEndpoint.port,
      );
      client.close(force: true);
      client = HttpClient();
      session = HttpEngineeringSessionStore(
        client: client,
        endpoint: server.endpoint,
        headers: () async => {'Authorization': 'Bearer $token'},
      );
      final persisted = await session.read();
      expect(persisted.version, resolved.revision.version);
      expect(persisted.document.objects['a']!.label, 'Right edit');
      expect(persisted.document.annotations, hasLength(2));
    },
  );

  test(
    'read-only grants, denial, authorization failure and recovery are enforced',
    () async {
      final before = await session.read();
      token = 'reader';
      expect((await session.read()).version, before.version);
      await expectLater(
        session.compareAndWrite(
          expectedVersion: before.version,
          document: seed(),
        ),
        throwsA(isA<HttpException>()),
      );
      token = 'invalid';
      await expectLater(session.read(), throwsA(isA<HttpException>()));
      token = 'writer';
      authFails = true;
      await expectLater(session.read(), throwsA(isA<HttpException>()));
      authFails = false;
      expect((await session.read()).version, before.version);
      expect(
        (await session.compareAndWrite(
          expectedVersion: before.version,
          document: seed(),
        )).version,
        isNot(before.version),
      );
    },
  );

  test(
    'preconditions, format, ownership and routing fail before persistence',
    () async {
      final before = await session.read();
      expect(await request('PUT', body: seed().encode()), 428);
      expect(await request('PUT', version: '*', body: seed().encode()), 400);
      expect(
        await request(
          'PUT',
          version: before.version,
          body: '{}',
          contentType: 'text/plain',
        ),
        415,
      );
      expect(
        await request('PUT', version: before.version, body: '{broken'),
        400,
      );
      expect(
        await request(
          'PUT',
          version: before.version,
          body: EngineeringDocument(id: 'another-review').encode(),
        ),
        400,
      );
      expect(await request('POST'), 405);
      expect(await request('GET', path: '/another-review'), 404);
      expect((await session.read()).version, before.version);
    },
  );

  test(
    'oversized and stalled request bodies fail without changing the revision',
    () async {
      final before = await session.read();
      final port = server.endpoint.port;
      await server.close();
      server = await EngineeringReviewServer.start(
        store: repository,
        authorize: (request, write) async => true,
        port: port,
        bodyTimeout: const Duration(milliseconds: 80),
      );
      Future<int> raw(int contentLength) async {
        final socket = await Socket.connect(InternetAddress.loopbackIPv4, port);
        try {
          socket.write(
            'PUT /review HTTP/1.1\r\nHost: 127.0.0.1\r\n'
            'Content-Type: application/json\r\nIf-Match: ${before.version}\r\n'
            'Connection: close\r\nContent-Length: $contentLength\r\n\r\n{',
          );
          await socket.flush();
          final response = await utf8.decoder
              .bind(socket)
              .join()
              .timeout(const Duration(seconds: 3));
          return int.parse(response.split(' ')[1]);
        } finally {
          socket.destroy();
        }
      }

      expect(await raw(EngineeringDocument.maxCharacters * 4 + 1), 413);
      expect(await raw(100), 408);
      expect((await session.read()).version, before.version);
    },
  );

  test(
    'a disconnected upload leaves the service and persisted review usable',
    () async {
      final before = await session.read();
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        server.endpoint.port,
      );
      socket.write(
        'PUT /review HTTP/1.1\r\nHost: 127.0.0.1\r\n'
        'Authorization: Bearer writer\r\nContent-Type: application/json\r\n'
        'If-Match: ${before.version}\r\nContent-Length: 100\r\n\r\n{',
      );
      await socket.flush();
      socket.destroy();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect((await session.read()).version, before.version);
    },
  );

  test('stale HTTP writers cannot overwrite a committed document', () async {
    final before = await session.read();
    final next = await session.compareAndWrite(
      expectedVersion: before.version,
      document: seed(),
    );
    await expectLater(
      session.compareAndWrite(
        expectedVersion: before.version,
        document: seed(),
      ),
      throwsA(isA<EngineeringVersionConflict>()),
    );
    expect((await session.read()).version, next.version);
  });
}
