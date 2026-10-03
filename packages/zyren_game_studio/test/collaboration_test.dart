import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_game_studio/export.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  test(
    'connected component and structural edits require leaving the room',
    () async {
      final authoring = createGameDevelopmentAuthoring();
      final document = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'shared').document;
      final authority = LocalSceneAuthority(
        initial: SceneSnapshot(
          sceneId: document.id,
          epoch: 'same-room',
          objects: [
            for (final node in document.expandedNodes.values)
              SceneObjectState(
                id: SceneObjectId(source: document.id, key: node.id),
              ),
          ],
        ),
        canRead: (_, _) => true,
        canWrite: (_, _, _) => true,
      );
      final client = SceneCollaborationClient(
        transport: authority.connect('owner'),
        sceneId: document.id,
        epoch: 'same-room',
        nextOperationId: () => 'op',
      );
      await client.refresh();
      final guard = GameCollaborationAdapter(connectedClient: () => client);
      final actor = document.expandedNodes.values.firstWhere(
        (n) => n.id == 'player',
      );
      final changed = authoring.setFields(
        document,
        nodeId: actor.id,
        component: 'game.character',
        fields: {'maxSpeed': 5},
      );
      expect(
        () => guard.guardDocument(document, changed),
        throwsA(isA<UnsupportedGameCollaboration>()),
      );
      expect(
        () => guard.guardDocument(
          document,
          StudioAuthoring.addBox(document, id: 'new'),
        ),
        throwsA(isA<UnsupportedGameCollaboration>()),
      );
      expect(guard.limitation, contains('Leave the shared session'));
      final moved = StudioAuthoring.updateNode(
        document,
        actor.id,
        StudioOverride(position: const Vec3(2, 0, 0), visible: false),
      );
      expect(() => guard.guardDocument(document, moved), returnsNormally);
      final prefab = StudioAuthoring.createPrefab(
        StudioDocument(
          id: document.id,
          title: 'Prefab',
          nodes: [StudioNode(id: 'root', label: 'Root')],
        ),
        'root',
        prefabId: 'guard',
      );
      final childId = prefab.expandedNodes.keys.firstWhere(
        (id) => id.contains('/'),
      );
      final prefabMoved = StudioAuthoring.updateNode(
        prefab,
        childId,
        StudioOverride(position: const Vec3(3, 0, 0)),
      );
      expect(() => guard.guardDocument(prefab, prefabMoved), returnsNormally);
      expect(client.snapshot!.revision, 0);
      await client.close();
      expect(guard.limitation, isNull);
      expect(() => guard.guardDocument(document, changed), returnsNormally);
    },
  );
  test(
    'shared authority preserves conflicting fields and checks lost grants',
    () async {
      final id = SceneObjectId(source: 'shared', key: 'player');
      var allowed = true, sequence = 0;
      final authority = LocalSceneAuthority(
        initial: SceneSnapshot(
          sceneId: 'shared',
          epoch: 'one',
          objects: [SceneObjectState(id: id)],
        ),
        canRead: (_, _) => true,
        canWrite: (_, _, _) => allowed,
      );
      SceneCollaborationClient client(String user) => SceneCollaborationClient(
        transport: authority.connect(user),
        sceneId: 'shared',
        epoch: 'one',
        nextOperationId: () => 'op-${++sequence}',
      );
      final first = client('first'), second = client('second');
      await first.refresh();
      await second.refresh();
      first.setVisible(id, false);
      second.setVisible(id, true);
      expect(await first.flush(), isA<SceneOperationAccepted>());
      expect(await second.flush(), isA<SceneOperationConflict>());
      expect(second.snapshot!.objects[id]!.visible, isFalse);
      second.keepLocal();
      allowed = false;
      await expectLater(second.flush(), throwsA(isA<SceneAccessDenied>()));
      expect(second.pending, isNotNull);
      allowed = true;
      expect(await second.flush(), isA<SceneOperationAccepted>());
      expect(second.snapshot!.revision, 2);
      await first.close();
      await second.close();
    },
  );
}
