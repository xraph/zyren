import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';

class LinkCodec extends GameComponentCodec<String> {
  @override
  String get type => 'game.link';
  @override
  int get version => 2;
  @override
  void validate(Map<String, Object?> data) {
    if (data['target'] is! String) throw FormatException('Missing target.');
  }

  @override
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data) {
    if (fromVersion != 1) throw FormatException('Unsupported link version.');
    return {'target': data['oldTarget']};
  }

  @override
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data) => [
    GameLocalReference(['target'], data['target'] as String),
  ];
  @override
  String factory(Map<String, Object?> data) => data['target'] as String;
}

class NestedCodec extends GameComponentCodec<int> {
  int calls = 0;
  @override
  String get type => 'nested';
  @override
  int get version => 1;
  @override
  void validate(Map<String, Object?> data) {}
  @override
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data) =>
      data;
  @override
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data) => [
    GameLocalReference([
      'links',
      0,
      'target',
    ], ((data['links'] as List).first as Map)['target'] as String),
  ];
  @override
  int factory(Map<String, Object?> data) => ++calls;
}

GameRegistry registry({GameLimits? limits}) =>
    GameRegistry(limits: limits)..registerComponent(LinkCodec());
GameEntityRecord entity(
  String id, [
  List<GameComponentRecord> components = const [],
]) => GameEntityRecord(id: id, components: components);
GameProject project(List<GameEntityRecord> entities, GameRegistry codecs) =>
    GameProject(
      id: 'courtyard',
      startupLevel: 'yard',
      registry: codecs,
      levels: [
        GameLevel(
          id: 'yard',
          scene: GameSceneIdentity('scene', 'sha256:pin'),
          entities: entities,
        ),
      ],
    );

void main() {
  test('project round trip keeps pins, metadata and components', () {
    final codecs = registry();
    final value = GameProject(
      id: 'courtyard',
      startupLevel: 'yard',
      registry: codecs,
      inputMaps: {
        'move': {
          'keys': ['W'],
        },
      },
      componentSchemas: {'game.link': 2},
      behaviorReferences: {'guard': 'brain-v1'},
      modelReferences: {
        'policy': {'version': 'v1'},
      },
      buildProfiles: {'native': {}},
      capabilityRequirements: ['native.physics'],
      levels: [
        GameLevel(
          id: 'yard',
          scene: GameSceneIdentity('scene', 'sha256:pin'),
          entities: [
            entity('a', [
              GameComponentRecord('game.link', 2, {'target': 'b'}),
            ]),
            entity('b'),
          ],
        ),
      ],
    );
    final restored = GameProject.decode(value.encode(), codecs);
    expect(jsonDecode(restored.encode()), jsonDecode(value.encode()));
    expect(restored.canActivate, isTrue);
    expect(restored.levels.single.scene.pin, 'sha256:pin');
  });
  test('duplicate entity, component and level IDs fail', () {
    final codecs = registry();
    expect(
      () => project([entity('a'), entity('a')], codecs),
      throwsFormatException,
    );
    expect(
      () => project([
        entity('a', [
          GameComponentRecord('game.link', 2, {'target': 'a'}),
          GameComponentRecord('game.link', 2, {'target': 'a'}),
        ]),
      ], codecs),
      throwsFormatException,
    );
    final level = GameLevel(
      id: 'yard',
      scene: GameSceneIdentity('scene', 'pin'),
      entities: [],
    );
    expect(
      () => GameProject(
        id: 'p',
        startupLevel: 'yard',
        registry: codecs,
        levels: [level, level],
      ),
      throwsFormatException,
    );
  });
  test('dangling local references fail before factories', () {
    expect(
      () => project([
        entity('a', [
          GameComponentRecord('game.link', 2, {'target': 'missing'}),
        ]),
      ], registry()),
      throwsFormatException,
    );
  });
  test('old versions migrate, validate and persist the current version', () {
    final codecs = registry();
    final restored = GameProject.decode(
      jsonEncode({
        'schemaVersion': 1,
        'id': 'p',
        'startupLevel': 'yard',
        'levels': [
          {
            'id': 'yard',
            'scene': {'id': 'scene', 'pin': 'pin'},
            'entities': [
              {
                'id': 'a',
                'components': [
                  {
                    'type': 'game.link',
                    'version': 1,
                    'data': {'oldTarget': 'a'},
                  },
                ],
              },
            ],
          },
        ],
      }),
      codecs,
    );
    final record = restored.levels.single.entities.single.components.single;
    expect(record.version, 2);
    expect(record.data, {'target': 'a'});
    expect(restored.canActivate, isTrue);
  });
  test(
    'unknown required and future records survive save and block activation',
    () {
      for (final type in ['missing.codec', 'game.link']) {
        final record = GameComponentRecord(type, 99, {
          'opaque': [
            1,
            {'field': true},
          ],
        });
        final value = project([
          entity('a', [record]),
        ], registry());
        expect(value.canActivate, isFalse);
        expect(value.activationProblems, isNotEmpty);
        final restored = GameProject.decode(value.encode(), registry());
        expect(
          restored.levels.single.entities.single.components.single.toJson(),
          record.toJson(),
        );
        expect(() => restored.requireActivation(), throwsStateError);
      }
      expect(
        project([
          entity('a', [GameComponentRecord('unknown', 1, {}, required: false)]),
        ], registry()).canActivate,
        isTrue,
      );
    },
  );
  test(
    'compiled local links remap for independent instances before factory calls',
    () {
      final recipe = GameSpawnTemplate(
        id: 'guard',
        registry: registry(),
        entities: [
          entity('actor', [
            GameComponentRecord('game.link', 2, {'target': 'target'}),
          ]),
          entity('target'),
        ],
      );
      final first = recipe.instantiate('first');
      final second = recipe.instantiate('second');
      expect(first.first.id, 'first/actor');
      expect(first.first.components.single.data['target'], 'first/target');
      expect(second.first.components.single.data['target'], 'second/target');
      expect(recipe.construct(first.first).single, 'first/target');
      expect(recipe.construct(second.first).single, 'second/target');
      expect(recipe.entities.first.components.single.data['target'], 'target');
    },
  );
  test(
    'slash and percent IDs remain independent across compiled instances',
    () {
      final recipe = GameSpawnTemplate(
        id: 'overlapping-paths',
        registry: registry(),
        entities: [
          entity('c', [
            GameComponentRecord('game.link', 2, {'target': 'b/c'}),
          ]),
          entity('b/c', [
            GameComponentRecord('game.link', 2, {'target': 'c'}),
          ]),
          entity('b%2Fc', [
            GameComponentRecord('game.link', 2, {'target': 'c'}),
          ]),
        ],
      );
      final table = GameEntityTable();
      for (final instanceId in ['a/b', 'a', 'a%2Fb']) {
        final spawned = recipe.instantiate(instanceId);
        final encodedInstance = Uri.encodeComponent(instanceId);
        expect(spawned.map((record) => record.id), [
          '$encodedInstance/c',
          '$encodedInstance/b%2Fc',
          '$encodedInstance/b%252Fc',
        ]);
        final ids = spawned.map((record) => record.id).toSet();
        for (final record in spawned) {
          final handle = table.spawn(record.id, components: record.components);
          expect(table.isAlive(handle), isTrue);
          final target = record.components.single.data['target'] as String;
          expect(ids, contains(target));
          expect(recipe.construct(record), [target]);
        }
        final reconstructed = GameEntityRecord.fromJson(spawned.first.toJson());
        expect(() => recipe.construct(reconstructed), throwsStateError);
      }
      expect(table.length, 9);
      expect(recipe.entities[1].id, 'b/c');
      expect(recipe.entities.first.components.single.data['target'], 'b/c');
      expect(() => recipe.construct(recipe.entities.first), throwsStateError);
      final other = GameSpawnTemplate(
        id: 'other-template',
        registry: registry(),
        entities: recipe.entities,
      );
      expect(
        () => recipe.construct(other.instantiate('a/b').first),
        throwsStateError,
      );
    },
  );
  test('factories require a remapped entity from this template', () {
    final recipe = GameSpawnTemplate(
      id: 'guard',
      registry: registry(),
      entities: [
        entity('actor', [
          GameComponentRecord('game.link', 2, {'target': 'target'}),
        ]),
        entity('target'),
      ],
    );
    expect(() => recipe.construct(recipe.entities.first), throwsStateError);
    final other = GameSpawnTemplate(
      id: 'other',
      registry: registry(),
      entities: [entity('actor')],
    );
    expect(
      () => recipe.construct(other.instantiate('other').first),
      throwsStateError,
    );
  });
  test('nested references remap exact fields without constructing early', () {
    final codec = NestedCodec();
    final codecs = GameRegistry()..registerComponent(codec);
    final recipe = GameSpawnTemplate(
      id: 'nested',
      registry: codecs,
      entities: [
        entity('a', [
          GameComponentRecord('nested', 1, {
            'links': [
              {'target': 'b', 'label': 'b'},
            ],
          }),
        ]),
        entity('b'),
      ],
    );
    final spawned = recipe.instantiate('one');
    expect(codec.calls, 0);
    expect(spawned.first.components.single.data['links'], [
      {'target': 'one/b', 'label': 'b'},
    ]);
    expect(recipe.construct(spawned.first), [1]);
  });
  test(
    'projects capture the registry and required recipes block before factories',
    () {
      final codecs = GameRegistry();
      final value = project([
        entity('a', [
          GameComponentRecord('game.link', 2, {'target': 'a'}),
        ]),
      ], codecs);
      codecs.registerComponent(LinkCodec());
      expect(value.canActivate, isFalse);
      expect(
        () => value.registry.registerComponent(LinkCodec()),
        throwsStateError,
      );
      final codec = NestedCodec();
      final recipe = GameSpawnTemplate(
        id: 'nested',
        registry: GameRegistry()..registerComponent(codec),
        entities: [
          entity('a', [
            GameComponentRecord('nested', 1, {
              'links': [
                {'target': 'b'},
              ],
            }),
          ]),
          entity('b', [GameComponentRecord('unknown', 1, {})]),
        ],
      );
      expect(() => recipe.instantiate('one'), throwsStateError);
      expect(codec.calls, 0);
    },
  );
  test(
    'registry, entity component, JSON node and UTF-8 bounds reject excess',
    () {
      final codecs = GameRegistry(limits: GameLimits(maxComponentTypes: 1))
        ..registerComponent(LinkCodec());
      expect(() => codecs.registerComponent(NestedCodec()), throwsStateError);
      final small = registry(limits: GameLimits(maxComponentsPerEntity: 1));
      expect(
        () => project([
          entity('a', [
            GameComponentRecord('one', 1, {}),
            GameComponentRecord('two', 1, {}),
          ]),
        ], small),
        throwsFormatException,
      );
      expect(
        () => GameComponentRecord('test', 1, {'items': List.filled(4097, 0)}),
        throwsFormatException,
      );
      expect(
        () => GameComponentRecord('test', 1, {'text': '🌍' * 20000}),
        throwsFormatException,
      );
    },
  );

  test('records deep copy and freeze JSON', () {
    final input = <String, Object?>{
      'nested': <Object?>[
        <String, Object?>{'value': 1},
      ],
    };
    final record = GameComponentRecord('test', 1, input);
    (input['nested'] as List).clear();
    expect((record.data['nested'] as List).length, 1);
    expect(
      () => (record.data['nested'] as List).clear(),
      throwsUnsupportedError,
    );
    expect(
      () => ((record.data['nested'] as List).first as Map)['value'] = 2,
      throwsUnsupportedError,
    );
    expect(
      () => GameComponentRecord('test', 1, {'invalid': Object()}),
      throwsFormatException,
    );
    expect(
      () => GameComponentRecord('test', 1, {'invalid': double.nan}),
      throwsFormatException,
    );
    final cycle = <Object?>[];
    cycle.add(cycle);
    expect(
      () => GameComponentRecord('test', 1, {'cycle': cycle}),
      throwsFormatException,
    );
  });
  test('limits can only decrease and bound project, registry and JSON', () {
    expect(() => GameLimits(maxEntities: 10001), throwsRangeError);
    expect(() => GameLimits(maxComponentsPerEntity: 65), throwsRangeError);
    expect(() => GameLimits(maxQueuedCommands: 4097), throwsRangeError);
    final codecs = registry(
      limits: GameLimits(maxEntities: 1, maxComponentsPerEntity: 1),
    );
    expect(
      () => project([entity('a'), entity('b')], codecs),
      throwsFormatException,
    );
    expect(() => codecs.registerComponent(LinkCodec()), throwsStateError);
    expect(
      () => GameProject.decode(' ' * (GameLimits.maxSourceBytes + 1), codecs),
      throwsFormatException,
    );
    Object? deep;
    for (var i = 0; i < 34; i++) {
      deep = [deep];
    }
    expect(
      () => GameComponentRecord('test', 1, {'deep': deep}),
      throwsFormatException,
    );
  });
  test('malformed project and unsupported schema reject without coercion', () {
    for (final source in [
      '[]',
      '{}',
      '{"schemaVersion":2}',
      '{"schemaVersion":1.0}',
    ]) {
      expect(
        () => GameProject.decode(source, registry()),
        throwsFormatException,
      );
    }
    expect(
      () => GameProject(
        id: 'p',
        startupLevel: 'absent',
        registry: registry(),
        levels: [],
      ),
      throwsFormatException,
    );
  });
}
