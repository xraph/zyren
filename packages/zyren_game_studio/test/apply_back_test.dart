import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_studio/apply_back.dart';
import 'package:zyren_game_studio/catalog.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  test('selected transforms and allowed fields form one undoable edit', () {
    final a = createGameAuthoring();
    var d = StudioDocument(
      id: 'scene',
      title: 'Scene',
      nodes: [StudioNode(id: 'actor', label: 'Actor')],
    );
    d = a.addComponent(d, 'actor', a.descriptors['game.character']!.create());
    final scene = StudioScene(d);
    final before = scene.document.encode();
    final apply = GameApplyBack(
      scene: scene,
      authoring: a,
      editableFields: {
        'game.character': {'maxSpeed'},
      },
    );
    final diff = apply.prepare(
      scene.revision,
      GameRuntimeSnapshot(
        buildId: 'fixture',
        tick: 3,
        entities: [
          GameRuntimeEntitySnapshot(
            nodeId: 'actor',
            position: const Vec3(2, 1, 0),
            rotation: Quat.identity,
            scale: Vec3.one,
            components: {
              'game.character': {'maxSpeed': 7, 'health': 0},
              'neural.state': {
                'hidden': [1],
              },
            },
          ),
        ],
      ),
    );
    expect(
      diff.fields.map((f) => f.path),
      unorderedEquals(['transform.position', 'game.character.maxSpeed']),
    );
    apply.commit(
      diff,
      expectedRevision: scene.revision,
      selectedFields: diff.fields.map((f) => f.id).toSet(),
    );
    expect(scene.document.nodes.single.position, const Vec3(2, 1, 0));
    expect(
      a.entityFor(scene.document, 'actor')!.components.single.data['maxSpeed'],
      7,
    );
    expect(scene.canUndo, isTrue);
    scene.undo();
    expect(scene.document.encode(), before);
    scene.redo();
    expect(scene.document.nodes.single.position, const Vec3(2, 1, 0));
  });
  test(
    'stale or unknown selected fields leave the authored document untouched',
    () {
      final scene = StudioScene(
        StudioDocument(
          id: 'scene',
          title: 'Scene',
          nodes: [StudioNode(id: 'actor', label: 'Actor')],
        ),
      );
      final apply = GameApplyBack(
        scene: scene,
        authoring: createGameAuthoring(),
      );
      final diff = apply.prepare(
        scene.revision,
        GameRuntimeSnapshot(
          buildId: 'fixture',
          tick: 1,
          entities: [
            GameRuntimeEntitySnapshot(
              nodeId: 'actor',
              position: const Vec3(1, 0, 0),
              rotation: Quat.identity,
              scale: Vec3.one,
            ),
          ],
        ),
      );
      expect(
        () => apply.commit(
          diff,
          expectedRevision: scene.revision,
          selectedFields: {'unknown'},
        ),
        throwsArgumentError,
      );
      scene.apply(scene.document.copyWith(title: 'Edited'));
      final before = scene.document.encode();
      expect(
        () => apply.commit(
          diff,
          expectedRevision: scene.revision,
          selectedFields: diff.fields.map((f) => f.id).toSet(),
        ),
        throwsA(isA<StaleApplyBack>()),
      );
      expect(scene.document.encode(), before);
    },
  );
}
