import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/file_store.dart';
import 'package:zyren_collaboration/network.dart';

final id = SceneObjectId(source: 'asset@1', key: 'box');
SceneSnapshot initial() => SceneSnapshot(
  sceneId: 'scene',
  epoch: 'one',
  objects: [SceneObjectState(id: id)],
);
SceneOperation visible(String key, int revision, bool value) => SceneOperation(
  sceneId: 'scene',
  epoch: 'one',
  operationId: key,
  objectId: id,
  expectedRevision: revision,
  field: SceneField.visibility,
  visible: value,
);
void main() {
  test(
    'HTTP and WebSocket share durable authority, leases, revocation and reconnect',
    () async {
      final dir = await Directory.systemTemp.createTemp('scene-network-');
      final authority = DurableSceneAuthority(
        store: FileSceneDocumentStore(File('${dir.path}/scene')),
        canRead: (_, _) => true,
        canWrite: (who, _, _) => who != 'viewer',
      );
      await authority.initialize(initial());
      var revoked = false;
      final presence = ScenePresenceAuthority(authorize: (_) => !revoked);
      Future<SceneCollaborationServer> server([int port = 0]) =>
          SceneCollaborationServer.bind(
            sceneId: 'scene',
            epoch: 'one',
            port: port,
            authenticate: (r) => revoked ? null : r.headers.value('x-user'),
            connect: authority.connect,
            presence: presence,
          );
      var host = await server();
      final http = HttpSceneTransport(
        endpoint: host.endpoint,
        sceneId: 'scene',
        epoch: 'one',
        headers: () => {'x-user': 'alice'},
      );
      final ws = WebSocketSceneTransport(
        endpoint: host.endpoint.replace(scheme: 'ws'),
        sceneId: 'scene',
        epoch: 'one',
        headers: () => {'x-user': 'bob'},
      );
      final viewer = HttpSceneTransport(
        endpoint: host.endpoint,
        sceneId: 'scene',
        epoch: 'one',
        headers: () => {'x-user': 'viewer'},
      );
      addTearDown(() async {
        await http.close();
        await ws.close();
        await viewer.close();
        await host.close();
        await dir.delete(recursive: true);
      });
      expect((await ws.read()).revision, 0);
      final changed = ws.changes.first;
      final accepted =
          await http.submit(visible('a', 0, false)) as SceneOperationAccepted;
      expect(accepted.committedRevision, 1);
      await changed.timeout(const Duration(seconds: 3));
      expect((await ws.read()).objects[id]!.visible, isFalse);
      expect(
        await ws.submit(visible('b', 0, true)),
        isA<SceneOperationConflict>(),
      );
      expect(
        (await http.submit(visible('a', 0, false)) as SceneOperationAccepted)
            .duplicate,
        isTrue,
      );
      expect((await ws.history(expectedRevision: 1)).records, hasLength(1));
      await expectLater(
        viewer.submit(visible('v', 1, true)),
        throwsA(isA<SceneAccessDenied>()),
      );
      await http.publishPresence(
        sessionId: 'alice-session',
        label: 'Alice',
        sequence: 1,
        camera: SharedSceneCamera.capture(
          PerspectiveCamera(position: const Vec3(4, 2, 6)),
        ),
      );
      final peers = await ws.participants();
      expect(peers.single.camera!.createCamera().position, const Vec3(4, 2, 6));
      expect((await ws.read()).revision, 1);
      await expectLater(
        ws.leave('alice-session'),
        throwsA(isA<SceneAccessDenied>()),
      );
      await http.undo(revision: 1, operationId: 'undo');
      expect((await ws.read()).objects[id]!.visible, isTrue);
      revoked = true;
      await expectLater(ws.read(), throwsA(isA<SceneAccessDenied>()));
      revoked = false;
      final port = host.endpoint.port;
      await host.close();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      host = await server(port);
      expect((await ws.read()).revision, 2);
    },
  );
  test(
    'offline file restart, lost acknowledgement and exact conflict decisions',
    () async {
      final dir = await Directory.systemTemp.createTemp('scene-outbox-');
      addTearDown(() => dir.delete(recursive: true));
      final host = LocalSceneAuthority(
        initial: initial(),
        canRead: (_, _) => true,
        canWrite: (_, _, _) => true,
      );
      final connection = host.connect('alice');
      final lost = LostReply(connection);
      OfflineSceneQueue queue() => OfflineSceneQueue(
        store: FileSceneDocumentStore(File('${dir.path}/outbox')),
        transport: lost,
        ownerId: 'alice',
        sceneId: 'scene',
        epoch: 'one',
      );
      await queue().initialize(await connection.read());
      await queue().enqueue(visible('offline', 0, false));
      var state = await queue().reconcile();
      expect(state.pending, hasLength(1));
      expect(state.lastError, 'retry_required');
      expect((await connection.read()).revision, 1);
      state = await queue().reconcile();
      expect(state.pending, isEmpty);
      expect(state.snapshot.revision, 1);
      await queue().enqueue(visible('local', 1, true));
      await host.connect('bob').submit(visible('remote', 1, false));
      state = await queue().reconcile();
      expect(state.conflict!.actualRevision, 2);
      await queue().keepLocal('decision', reviewed: state.conflict!);
      await host.connect('bob').submit(visible('intervening', 2, false));
      expect((await queue().reconcile()).conflict!.actualRevision, 3);
      await expectLater(
        queue().acceptRemote(reviewed: state.conflict!),
        throwsA(isA<SceneRevisionMismatch>()),
      );
      await queue().acceptRemote(reviewed: (await queue().read()).conflict!);
      expect((await queue().read()).pending, isEmpty);
      await queue().enqueue(visible('last', 3, true));
      lost.denied = true;
      state = await queue().reconcile();
      expect(state.lastError, 'denied');
      expect(state.pending, hasLength(1));
      await expectLater(
        queue().acceptRemote(
          reviewed:
              state.conflict ??
              SceneOperationConflict(
                operation: visible('dummy', 0, true),
                snapshot: state.snapshot,
              ),
        ),
        throwsStateError,
      );
      final other = OfflineSceneQueue(
        store: FileSceneDocumentStore(File('${dir.path}/outbox')),
        transport: lost,
        ownerId: 'alice',
        sceneId: 'scene',
        epoch: 'two',
      );
      await expectLater(other.read(), throwsA(isA<SceneSessionMismatch>()));
      final foreign = OfflineSceneQueue(
        store: FileSceneDocumentStore(File('${dir.path}/outbox')),
        transport: lost,
        ownerId: 'bob',
        sceneId: 'scene',
        epoch: 'one',
      );
      await expectLater(foreign.read(), throwsA(isA<SceneAccessDenied>()));
    },
  );
  test(
    'presence expiry, ordering, rate bounds and camera follow lifecycle',
    () async {
      var now = DateTime.utc(2026);
      final host = ScenePresenceAuthority(
        authorize: (_) => true,
        clock: () => now,
        lease: const Duration(seconds: 2),
      );
      final a = host.connect('a'), b = host.connect('b');
      final camera = OrthographicCamera(
        position: const Vec3(0, 0, 8),
        verticalSize: 6,
      );
      await a.publishPresence(
        sessionId: 'a',
        label: 'A',
        sequence: 1,
        camera: SharedSceneCamera.capture(camera),
      );
      await expectLater(
        a.publishPresence(sessionId: 'a', label: 'A', sequence: 1),
        throwsA(isA<SceneRevisionMismatch>()),
      );
      await expectLater(
        a.publishPresence(sessionId: 'a', label: 'A', sequence: 2),
        throwsStateError,
      );
      Camera? applied;
      final follower = SharedCameraFollower(apply: (c) => applied = c);
      addTearDown(follower.close);
      follower.follow('a');
      follower.update(await b.participants(), now: now);
      expect(
        (applied as OrthographicCamera).projectionMatrix(2),
        camera.projectionMatrix(2),
      );
      follower.stop();
      expect(follower.sessionId, isNull);
      follower.follow('a');
      now = now.add(const Duration(seconds: 3));
      follower.update(await b.participants(), now: now);
      expect(follower.sessionId, isNull);
      expect(await a.participants(), isEmpty);
      expect(
        () => SharedSceneCamera.fromJson({'kind': 'perspective'}),
        throwsA(isA<FormatException>()),
      );
    },
  );
  test('nonlocal plaintext endpoints are rejected', () {
    expect(
      () => HttpSceneTransport(
        endpoint: Uri.parse('http://example.com/scene'),
        sceneId: 's',
        epoch: 'e',
        headers: () => {},
      ),
      throwsArgumentError,
    );
  });
}

final class LostReply implements SceneOperationTransport {
  final SceneOperationTransport inner;
  bool lose = true, denied = false;
  LostReply(this.inner);
  @override
  Future<SceneSnapshot> read() => inner.read();
  @override
  Future<SceneOperationResult> submit(SceneOperation op) async {
    if (denied) throw const SceneAccessDenied();
    final result = await inner.submit(op);
    if (lose) {
      lose = false;
      throw const SocketException('Lost reply');
    }
    return result;
  }
}
