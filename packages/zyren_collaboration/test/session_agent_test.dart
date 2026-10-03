import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/agent_provider.dart';

void main() {
  test(
    'shared registry exposes leases, explicit follow, guarded undo and persistent queue state',
    () async {
      final id = SceneObjectId(source: 'asset', key: 'box');
      final authority = LocalSceneAuthority(
        initial: SceneSnapshot(
          sceneId: 's',
          epoch: 'e',
          objects: [SceneObjectState(id: id)],
        ),
        canRead: (_, _) => true,
        canWrite: (_, _, _) => true,
      );
      var sequence = 0;
      final client = SceneCollaborationClient(
        transport: authority.connect('alice'),
        sceneId: 's',
        epoch: 'e',
        nextOperationId: () => 'a-${++sequence}',
      );
      await client.refresh();
      client.setVisible(id, false);
      await client.flush();
      final presence = ScenePresenceAuthority(authorize: (_) => true);
      await presence
          .connect('bob')
          .publishPresence(
            sessionId: 'bob',
            label: 'Bob',
            sequence: 1,
            camera: SharedSceneCamera.capture(
              PerspectiveCamera(position: const Vec3(3, 2, 5)),
            ),
          );
      Camera? applied;
      final follower = SharedCameraFollower(
        apply: (camera) => applied = camera,
      );
      final queue = OfflineSceneQueue(
        store: MemorySceneDocumentStore(),
        transport: client.transport,
        sceneId: 's',
        epoch: 'e',
        ownerId: 'alice',
      );
      await queue.initialize(client.snapshot!);
      final provider = CollaborationAgentProvider(
        client: client,
        instanceId: 'main',
        documentId: 'scene',
        presence: presence.connect('alice'),
        offline: queue,
        cameraFollower: follower,
      );
      final registry = AgentRegistry(
        grantedScopes: {
          'collaboration.read',
          'collaboration.write',
          'collaboration.camera',
        },
      );
      registry.register(provider);
      addTearDown(() async {
        registry.dispose();
        follower.close();
        await client.close();
      });
      Future<AgentResult> call(
        String name, [
        Map<String, Object?> args = const {},
        bool write = false,
      ]) => registry.call(
        providerId: provider.id,
        instanceId: 'main',
        tool: name,
        arguments: args,
        expectedRevision: write ? provider.revision : null,
        idempotencyKey: write ? 'call-${++sequence}' : null,
      );
      expect((await call('presence')).data['participants'], hasLength(1));
      expect(
        (await call('follow_camera', {'sessionId': 'bob'}, true)).status,
        AgentStatus.ok,
      );
      expect(applied!.position, const Vec3(3, 2, 5));
      expect(
        (await call('undo', {'revision': 1}, true)).status,
        AgentStatus.ok,
      );
      expect(client.snapshot!.objects[id]!.visible, isTrue);
      expect((await call('offline_state')).status, AgentStatus.ok);
      expect((await call('reconcile', {}, true)).status, AgentStatus.ok);
      final checkpoint = (await queue.read()).snapshot;
      await queue.enqueue(
        SceneOperation(
          sceneId: 's',
          epoch: 'e',
          operationId: 'queued',
          objectId: id,
          expectedRevision: checkpoint.objects[id]!.visibilityRevision,
          field: SceneField.visibility,
          visible: false,
        ),
      );
      await authority
          .connect('bob')
          .submit(
            SceneOperation(
              sceneId: 's',
              epoch: 'e',
              operationId: 'remote',
              objectId: id,
              expectedRevision: checkpoint.objects[id]!.visibilityRevision,
              field: SceneField.visibility,
              visible: true,
            ),
          );
      expect((await call('reconcile', {}, true)).status, AgentStatus.ok);
      final conflict = (await queue.read()).conflict!;
      expect(
        (await call('offline_keep_local', {
          'operationId': 'queued',
          'sceneRevision': conflict.snapshot.revision,
          'fieldRevision': conflict.actualRevision - 1,
        }, true)).status,
        AgentStatus.stale,
      );
      expect(
        (await call('offline_keep_local', {
          'operationId': 'queued',
          'sceneRevision': conflict.snapshot.revision,
          'fieldRevision': conflict.actualRevision,
        }, true)).status,
        AgentStatus.ok,
      );
      expect((await call('reconcile', {}, true)).status, AgentStatus.ok);
      expect(client.snapshot!.objects[id]!.visible, isFalse);
      expect((await call('stop_following', {}, true)).status, AgentStatus.ok);
      expect(follower.sessionId, isNull);
    },
  );
}
