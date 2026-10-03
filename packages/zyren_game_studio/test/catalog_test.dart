import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/catalog.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  test(
    'built-in descriptors use supported runtime codecs and consumed fields',
    () {
      final authoring = createGameAuthoring();
      expect(createGameComponentCatalog(), hasLength(8));
      for (final descriptor in authoring.descriptors.values) {
        final record = descriptor.create();
        expect(authoring.registry.supports(record), isTrue);
        expect(authoring.registry.construct(record), isNotNull);
      }
      final character = authoring.descriptors['game.character']!;
      expect(
        character.fields.map((field) => field.name),
        isNot(contains('radius')),
      );
      expect(
        character.fields.map((field) => field.name),
        isNot(contains('height')),
      );
      expect(
        authoring.descriptors['game.vehicle']!.fields
            .singleWhere((f) => f.name == 'wheels')
            .entryTemplate,
        isNotNull,
      );
    },
  );
  test('shared runtime definitions reject the same invalid editor data', () {
    final authoring = createGameAuthoring();
    var document = StudioDocument(
      id: 'scene',
      title: 'Scene',
      nodes: [StudioNode(id: 'guard', label: 'Guard')],
    );
    document = authoring.addComponent(
      document,
      'guard',
      authoring.descriptors['game.character']!.create(),
    );
    expect(
      () => authoring.setField(
        document,
        nodeId: 'guard',
        component: 'game.character',
        field: 'maxSpeed',
        value: 101,
      ),
      throwsA(isA<GameAuthoringException>()),
    );
    expect(() => GameCharacterDefinition(maxSpeed: 101), throwsArgumentError);
    final vehicle = authoring.descriptors['game.vehicle']!.create();
    expect(
      () => authoring.registry.construct(
        GameComponentRecord('game.vehicle', 1, {
          ...vehicle.data,
          'wheelbase': 3,
        }),
      ),
      throwsArgumentError,
    );
    expect(
      () => VehicleDefinition.fromJson({...vehicle.data, 'wheelbase': 3}),
      throwsArgumentError,
    );
  });
  test(
    'persisted character and vehicle prefab copies retain independent runtime schemas',
    () async {
      final authoring = createGameAuthoring();
      var document = StudioDocument(
        id: 'scene',
        title: 'Scene',
        nodes: [
          StudioNode(id: 'guard', label: 'Guard'),
          StudioNode(id: 'buggy', label: 'Buggy'),
        ],
      );
      document = authoring.addComponent(
        document,
        'guard',
        authoring.descriptors['game.character']!.create(),
      );
      document = authoring.addComponent(
        document,
        'buggy',
        authoring.descriptors['game.vehicle']!.create(),
      );
      document = authoring.addComponent(
        document,
        'guard',
        GameComponentRecord('game.camera', 1, {
          ...authoring.descriptors['game.camera']!.create().data,
          'target': 'guard',
        }),
      );
      document = authoring.addComponent(
        document,
        'buggy',
        GameComponentRecord('game.interaction', 1, {
          ...authoring.descriptors['game.interaction']!.create().data,
          'target': 'buggy',
        }),
      );
      document = authoring.createPrefab(
        document,
        'guard',
        prefabId: 'guard-prefab',
      );
      document = authoring.createPrefab(
        document,
        'buggy',
        prefabId: 'buggy-prefab',
      );
      document = authoring.duplicate(document, 'guard', newId: 'guard-copy');
      document = authoring.duplicate(document, 'buggy', newId: 'buggy-copy');
      final directory = await Directory.systemTemp.createTemp('game-catalog-');
      addTearDown(() => directory.delete(recursive: true));
      final saved = File('${directory.path}/scene.json');
      await saved.writeAsString(document.encode());
      final restored = StudioDocument.decode(await saved.readAsString());
      final restarted = createGameAuthoring();
      expect(restarted.validate(restored), isEmpty);
      final entities = restarted.expanded(restored).entities;
      expect(entities, hasLength(4));
      expect(entities.map((e) => e.id).toSet(), hasLength(4));
      final characterDefinitions = entities
          .expand((e) => e.components)
          .where((c) => c.type == 'game.character')
          .map(restarted.registry.construct)
          .cast<GameCharacterDefinition>()
          .toList();
      final vehicleDefinitions = entities
          .expand((e) => e.components)
          .where((c) => c.type == 'game.vehicle')
          .map(restarted.registry.construct)
          .cast<VehicleDefinition>()
          .toList();
      for (final entity in entities) {
        final references = entity.components.where(
          (c) => c.type == 'game.camera' || c.type == 'game.interaction',
        );
        expect(references.single.data['target'], entity.id);
      }
      expect(characterDefinitions, hasLength(2));
      expect(vehicleDefinitions, hasLength(2));
      expect(
        identical(characterDefinitions[0], characterDefinitions[1]),
        isFalse,
      );
      expect(identical(vehicleDefinitions[0], vehicleDefinitions[1]), isFalse);
      expect(
        identical(vehicleDefinitions[0].wheels, vehicleDefinitions[1].wheels),
        isFalse,
      );
      final edited = restarted.setField(
        restored,
        nodeId: 'guard-copy/guard',
        component: 'game.character',
        field: 'maxSpeed',
        value: 7,
      );
      expect(
        restarted
            .entityFor(edited, 'guard-copy/guard')!
            .components
            .singleWhere((component) => component.type == 'game.character')
            .data['maxSpeed'],
        7,
      );
      expect(
        restarted
            .entityFor(edited, 'guard/guard')!
            .components
            .singleWhere((component) => component.type == 'game.character')
            .data['maxSpeed'],
        4,
      );
    },
  );
}
