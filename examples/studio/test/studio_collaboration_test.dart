import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/network.dart';
import 'package:zyren_studio_example/studio_collaboration.dart';

StudioScene fixture() => StudioScene(
  StudioDocument(
    id: 'room',
    title: 'Room',
    nodes: [StudioNode(id: 'part', label: 'Part')],
  ),
);

void main() {
  test(
    'durable sessions retain conflicts, conditional inverse history, presence and grants',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'studio-session-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final sceneA = fixture(), sceneB = fixture();
      final room = await StudioRoom.host(sceneA, directory);
      addTearDown(room.close);
      Future<StudioCollaborationSession> connect(
        StudioScene scene,
        String principal,
      ) => StudioCollaborationSession.connect(
        scene: scene,
        transport: room.authority.connect(principal),
        presence: room.presence.connect(principal),
        directory: directory,
        ownerId: principal,
        label: principal,
      );
      final a = await connect(sceneA, 'owner');
      final b = await connect(sceneB, 'editor');
      addTearDown(a.close);
      addTearDown(b.close);
      final first =
          await a.transform(
                'part',
                SceneTransform(position: const Vec3(1, 0, 0)),
              )
              as SceneOperationAccepted;
      final conflict = await b.transform(
        'part',
        SceneTransform(position: const Vec3(2, 0, 0)),
      );
      expect(conflict, isA<SceneOperationConflict>());
      expect(sceneB.objects['part']!.position.x, 1);
      expect(b.client.pending, isNotNull);
      final kept = await b.keepLocal() as SceneOperationAccepted;
      expect(sceneB.objects['part']!.position.x, 2);
      expect(
        await a.undo(first.committedRevision),
        isA<SceneOperationConflict>(),
      );
      await a.acceptRemote();
      final inverse =
          await b.undo(kept.committedRevision) as SceneOperationAccepted;
      expect(sceneB.objects['part']!.position.x, 1);
      await b.undo(inverse.committedRevision);
      expect(sceneB.objects['part']!.position.x, 2);
      await b.publish(1, selectedId: 'part', shareCamera: true);
      final people = await a.presence.participants();
      expect(people.single.label, 'editor');
      a.follower.follow(b.sessionId);
      a.follower.update(people);
      expect(a.follower.sessionId, b.sessionId);
      a.follower.stop();
      final registry = AgentRegistry(
        grantedScopes: {'collaboration.read', 'collaboration.write'},
      );
      addTearDown(registry.dispose);
      final provider = StudioCollaborationAgentProvider(a);
      registry.register(provider);
      expect(
        await AgentConformance.checkRead(
          registry: registry,
          provider: provider,
          tool: 'state',
        ),
        isEmpty,
      );
      await a.refresh();
      final result = await registry.call(
        providerId: provider.id,
        instanceId: provider.instanceId,
        tool: 'set_visibility',
        expectedRevision: provider.revision,
        idempotencyKey: 'visibility',
        arguments: {'source': 'room', 'key': 'part', 'visible': false},
      );
      expect(result.status, AgentStatus.ok);
      expect(sceneA.objects['part']!.visible, isFalse);
      final viewer = await connect(fixture(), 'viewer');
      addTearDown(viewer.close);
      await expectLater(
        viewer.visible('part', true),
        throwsA(isA<SceneAccessDenied>()),
      );
    },
  );

  test(
    'lost receipt survives restart and retries the exact operation once',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'studio-recovery-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final room = await StudioRoom.host(fixture(), directory);
      addTearDown(room.close);
      final interrupted = await StudioCollaborationSession.connect(
        scene: fixture(),
        transport: _LoseReceipt(room.authority.connect('owner')),
        presence: room.presence.connect('owner'),
        directory: directory,
        ownerId: 'owner',
        label: 'Owner',
      );
      await expectLater(
        interrupted.transform(
          'part',
          SceneTransform(position: const Vec3(4, 0, 0)),
        ),
        throwsStateError,
      );
      final operationId = interrupted.client.pending!.operationId;
      await interrupted.close();
      final restoredScene = fixture();
      final restored = await StudioCollaborationSession.connect(
        scene: restoredScene,
        transport: room.authority.connect('owner'),
        presence: room.presence.connect('owner'),
        directory: directory,
        ownerId: 'owner',
        label: 'Owner',
      );
      addTearDown(restored.close);
      expect(restored.client.pending!.operationId, operationId);
      expect(restoredScene.objects['part']!.position.x, 4);
      final result = await restored.retryPending() as SceneOperationAccepted;
      expect(result.duplicate, isTrue);
      expect(result.snapshot.revision, 1);
      expect(restored.client.pending, isNull);
    },
  );

  test(
    'offline outbox requires explicit conflict decisions and remote viewers cannot write',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'studio-offline-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final room = await StudioRoom.host(fixture(), directory);
      addTearDown(room.close);
      final scene = fixture();
      final session = await StudioCollaborationSession.connect(
        scene: scene,
        transport: room.authority.connect('owner'),
        presence: room.presence.connect('owner'),
        directory: directory,
        ownerId: 'owner',
        label: 'Owner',
      );
      addTearDown(session.close);
      await session.queueTransform(
        'part',
        SceneTransform(position: const Vec3(5, 0, 0)),
      );
      final other = SceneCollaborationClient(
        transport: room.authority.connect('editor'),
        sceneId: 'room',
        epoch: studioEpoch(scene.document),
        nextOperationId: () => 'other',
      );
      addTearDown(other.close);
      await other.refresh();
      other.setTransform(
        SceneObjectId(source: 'room', key: 'part'),
        SceneTransform(position: const Vec3(6, 0, 0)),
      );
      await other.flush();
      final state = await session.reconcile();
      expect(state.conflict, isNotNull);
      expect(scene.objects['part']!.position.x, 6);
      await session.offline.acceptRemote(reviewed: state.conflict!);
      expect((await session.offline.read()).pending, isEmpty);
      final network = HttpSceneTransport(
        endpoint: room.server.endpoint,
        sceneId: 'room',
        epoch: studioEpoch(scene.document),
        headers: () => {'Authorization': 'Bearer ${room.viewerToken}'},
      );
      addTearDown(network.close);
      expect((await network.read()).revision, 1);
      final viewer = SceneCollaborationClient(
        transport: network,
        sceneId: 'room',
        epoch: studioEpoch(scene.document),
        nextOperationId: () => 'denied',
      );
      addTearDown(viewer.close);
      await viewer.refresh();
      viewer.setVisible(SceneObjectId(source: 'room', key: 'part'), false);
      await expectLater(viewer.flush(), throwsA(isA<SceneAccessDenied>()));
      expect((await network.read()).objects.values.single.visible, isTrue);
      final changed = scene.document.copyWith(
        nodes: [StudioNode(id: 'different', label: 'Different')],
      );
      expect(studioEpoch(changed), isNot(studioEpoch(scene.document)));
    },
  );
}

class _LoseReceipt implements SceneOperationTransport {
  final SceneOperationTransport base;
  _LoseReceipt(this.base);
  @override
  Future<SceneSnapshot> read() => base.read();
  @override
  Future<SceneOperationResult> submit(SceneOperation operation) async {
    await base.submit(operation);
    throw StateError('Connection lost after commit');
  }
}
