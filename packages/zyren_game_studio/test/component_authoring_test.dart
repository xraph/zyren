import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'package:zyren_game_studio/authoring.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_game_studio/catalog.dart';
import 'compiler_test.dart' show Link, document;

GameAuthoring authoring({Set<String> dependencies = const {}}) => GameAuthoring(
  GameRegistry()..registerComponent(Link()),
  descriptors: [
    GameComponentDescriptor(
      type: 'test.link',
      label: 'Link',
      dependencies: dependencies,
      fields: const [
        GameFieldDescriptor('target', 'Target', GameFieldKind.entity),
        GameFieldDescriptor(
          'value',
          'Value',
          GameFieldKind.integer,
          minimum: 0,
          maximum: 10,
          unit: 'm',
        ),
      ],
    ),
  ],
);
StudioDocument plain() => StudioDocument(
  id: 'game',
  title: 'Game',
  nodes: [StudioNode(id: 'actor', label: 'Actor')],
);
void main() {
  test(
    'invalid prefab definitions and instance overrides stay inspectable and repairable',
    () {
      final edits = createGameAuthoring();
      var source = edits.addComponent(
        plain(),
        'actor',
        edits.descriptors['game.character']!.create(),
      );
      source = edits.createPrefab(source, 'actor', prefabId: 'character');
      final prefab = source.prefabs.single;
      final data = edits.codec.read(prefab.extensions['zyren.game']!);
      final broken = source.copyWith(
        prefabs: [
          prefab.copyWith(
            extensions: {
              'zyren.game': edits.codec.write(
                GameDocumentData(
                  projectId: data.projectId,
                  levelId: data.levelId,
                  entities: [
                    GameEntityRecord(
                      id: 'actor',
                      nodeId: 'actor',
                      components: [
                        GameComponentRecord('game.character', 1, {
                          ...data.entities.single.components.single.data,
                          'maxSpeed': 101,
                        }),
                      ],
                    ),
                  ],
                ),
              ),
            },
          ),
        ],
      );
      final issues = edits.validate(broken);
      expect(
        issues.any((i) => i.nodeId == 'actor/actor' && i.field == 'maxSpeed'),
        isTrue,
      );
      expect(
        edits
            .entityFor(broken, 'actor/actor')!
            .components
            .single
            .data['maxSpeed'],
        101,
      );
      expect(() => edits.expanded(broken), throwsArgumentError);
      final repair = issues
          .map((i) => i.repair)
          .whereType<GameRepairCommand>()
          .firstWhere((r) => r.kind == GameRepairKind.resetPrefabComponent);
      final repaired = edits.repair(broken, repair);
      expect(edits.validate(repaired), isEmpty);
      (StudioExtensionRegistry()..register(edits.codec)).validateDocument(
        repaired,
        requireSupported: true,
      );
      final badOverride = source.copyWith(
        nodes: [
          source.nodes.single.copyWith(
            extensionOverrides: {
              'zyren.game': {
                'entities': {
                  'actor': {
                    'components': {
                      'game.character': {'maxSpeed': 101},
                    },
                  },
                },
              },
            },
          ),
        ],
      );
      expect(
        edits
            .validate(badOverride)
            .any((i) => i.nodeId == 'actor/actor' && i.field == 'maxSpeed'),
        isTrue,
      );
      final next = edits.setField(
        badOverride,
        nodeId: 'actor/actor',
        component: 'game.character',
        field: 'maxSpeed',
        value: 5,
      );
      expect(edits.validate(next), isEmpty);
      expect(
        edits
            .entityFor(next, 'actor/actor')!
            .components
            .single
            .data['maxSpeed'],
        5,
      );
    },
  );
  test(
    'malformed saved fields and missing targets report precise repair locations',
    () {
      final edits = authoring();
      final broken = plain().copyWith(
        extensions: {
          'zyren.game': edits.codec.write(
            GameDocumentData(
              projectId: 'game',
              levelId: 'game',
              entities: [
                GameEntityRecord(
                  id: 'actor',
                  nodeId: 'actor',
                  components: [
                    GameComponentRecord('test.link', 1, {
                      'target': 'missing',
                      'value': 99,
                    }),
                  ],
                ),
              ],
            ),
          ),
        },
      );
      final issues = edits.validate(broken);
      expect(
        issues.any(
          (i) =>
              i.nodeId == 'actor' &&
              i.component == 'test.link' &&
              i.field == 'value',
        ),
        isTrue,
      );
      expect(
        issues.any(
          (i) =>
              i.field == 'target' &&
              i.repair?.kind == GameRepairKind.selectTarget,
        ),
        isTrue,
      );
      final next = edits.setFields(
        broken,
        nodeId: 'actor',
        component: 'test.link',
        fields: {'target': 'actor', 'value': 4},
      );
      expect(edits.validate(next), isEmpty);
    },
  );
  test(
    'prefab creation and hierarchy duplication remap reference identity once',
    () {
      final edits = authoring();
      final start = edits.addComponent(
        plain(),
        'actor',
        GameComponentRecord('test.link', 1, {'target': 'actor', 'value': 1}),
      );
      final prefab = edits.createPrefab(start, 'actor', prefabId: 'character');
      expect(prefab.prefabs.single.extensions, contains('zyren.game'));
      final one = edits.expanded(prefab).entities.single;
      expect(one.nodeId, 'actor/actor');
      expect(one.components.single.data['target'], one.id);
      final copy = edits.duplicate(prefab, 'actor', newId: 'second');
      final restored = StudioDocument.decode(copy.encode());
      final entities = edits.expanded(restored).entities;
      expect(entities, hasLength(2));
      for (final e in entities) {
        expect(e.components.single.data['target'], e.id);
      }
      final plainCopy = edits.duplicate(start, 'actor', newId: 'copy');
      expect(
        edits.entityFor(plainCopy, 'copy')!.components.single.data['target'],
        'copy',
      );
      expect(
        edits.entityFor(plainCopy, 'actor')!.components.single.data['target'],
        'actor',
      );
    },
  );
  test('component addition removal typed fields and atomic shared undo', () {
    final edits = authoring();
    final start = edits.addComponent(
      plain(),
      'actor',
      GameComponentRecord('test.link', 1, {'target': 'actor', 'value': 1}),
    );
    final registry = StudioExtensionRegistry()..register(edits.codec);
    final scene = StudioScene(start, extensionRegistry: registry);
    scene.apply(
      edits.setFields(
        start,
        nodeId: 'actor',
        component: 'test.link',
        fields: {'target': 'actor', 'value': 4},
      ),
    );
    expect(
      edits.entityFor(scene.document, 'actor')!.components.single.data['value'],
      4,
    );
    scene.undo();
    expect(scene.document.encode(), start.encode());
    expect(
      () => edits.setField(
        start,
        nodeId: 'actor',
        component: 'test.link',
        field: 'value',
        value: 20,
      ),
      throwsA(isA<GameAuthoringException>()),
    );
    expect(
      () => edits.setField(
        start,
        nodeId: 'actor',
        component: 'test.link',
        field: 'bad',
        value: 2,
      ),
      throwsA(isA<GameAuthoringException>()),
    );
    final removed = edits.removeComponent(
      start,
      nodeId: 'actor',
      component: 'test.link',
    );
    expect(edits.entityFor(removed, 'actor')!.components, isEmpty);
  });
  test('missing dependencies produce node issue and concrete repair', () {
    final edits = authoring(dependencies: {'test.body'});
    try {
      edits.addComponent(
        plain(),
        'actor',
        GameComponentRecord('test.link', 1, {'target': 'actor', 'value': 1}),
      );
      fail('dependency should be required');
    } on GameAuthoringException catch (error) {
      expect(error.issues.single.nodeId, 'actor');
      expect(error.issues.single.repair!.kind, GameRepairKind.addDependency);
      expect(error.issues.single.repair!.component, 'test.body');
    }
  });
  test(
    'prefab overrides preserve inherited values and independent restart identities',
    () {
      final edits = authoring();
      for (final nested in [false, true]) {
        final initial = document(edits.codec, nested: nested);
        final nodeId = nested ? 'instance/nested/kid' : 'instance/kid';
        final next = edits.setField(
          initial,
          nodeId: nodeId,
          component: 'test.link',
          field: 'value',
          value: 7,
        );
        expect(
          edits.fieldOrigin(
            next,
            nodeId: nodeId,
            component: 'test.link',
            field: 'value',
          ),
          GameFieldOrigin.overridden,
        );
        expect(
          edits.fieldOrigin(
            next,
            nodeId: nodeId,
            component: 'test.link',
            field: 'target',
          ),
          GameFieldOrigin.inherited,
        );
        final duplicate = StudioAuthoring.instancePrefab(
          next,
          nested ? 'outer' : 'inner',
          id: 'second',
        );
        final restored = StudioDocument.decode(duplicate.encode());
        final entities = edits.expanded(restored).entities;
        expect(entities.map((e) => e.id).toSet(), hasLength(2));
        expect(entities.map((e) => e.components.single.data['value']), [7, 1]);
        for (final entity in entities) {
          expect(entity.components.single.data['target'], entity.id);
        }
        final reset = edits.resetPrefabFields(
          next,
          instanceId: 'instance',
          entityId: nested ? 'nested/kid' : 'kid',
          component: 'test.link',
          fields: {'value'},
        );
        expect(
          edits.entityFor(reset, nodeId)!.components.single.data['value'],
          1,
        );
        expect(
          edits.fieldOrigin(
            reset,
            nodeId: nodeId,
            component: 'test.link',
            field: 'value',
          ),
          GameFieldOrigin.inherited,
        );
      }
    },
  );
}
