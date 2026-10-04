import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  test(
    'standalone registry decodes the same AI pins and exact training bindings',
    () {
      final registry = GameRegistry();
      registerGameAiCodecs(registry);
      for (final profile in ['guard', 'vehicle']) {
        final definition =
            registry.construct(
                  GameComponentRecord('game.ai', 1, {
                    'profile': profile,
                    'brain': 'scripted',
                  }),
                )
                as GameAiAuthoringDefinition;
        expect(
          definition.createSensors().spec.hash,
          (profile == 'guard'
                  ? TrainingProfiles.guard()
                  : TrainingProfiles.vehicle())
              .spec
              .hash,
        );
        expect(
          definition.createActions().spec.hash,
          (profile == 'guard'
                  ? ActionDecoder.characterDiscrete()
                  : ActionDecoder.vehiclePedals())
              .spec
              .hash,
        );
      }
    },
  );
  test(
    'learned authoring requires model SHA and unknown profile is rejected',
    () {
      final registry = GameRegistry();
      registerGameAiCodecs(registry);
      expect(
        () => registry.construct(
          GameComponentRecord('game.ai', 1, {
            'profile': 'guard',
            'brain': 'learned',
          }),
        ),
        throwsArgumentError,
      );
      expect(
        () => registry.construct(
          GameComponentRecord('game.ai', 1, {
            'profile': 'omniscient',
            'brain': 'scripted',
          }),
        ),
        throwsArgumentError,
      );
      final pinned =
          registry.construct(
                GameComponentRecord('game.ai', 1, {
                  'profile': 'vehicle',
                  'brain': 'hybrid',
                  'modelHash': 'a' * 64,
                }),
              )
              as GameAiAuthoringDefinition;
      expect(pinned.modelHash, 'a' * 64);
    },
  );
  test(
    'multi authoring pins shared schemas, roles and bounded immutable routes',
    () {
      final route = <Object?>[
        <num>[2, .81, 4],
      ];
      final definition = GameAiAuthoringDefinition({
        'profile': 'guard',
        'brain': 'scripted',
        'multiTask': 'cooperative-search',
        'teamId': 'search-team',
        'multiRole': 'searcher',
        'goalEntityId': 'goal',
        'authoredRoute': route,
      });
      final profile = TrainingMultiProfiles.forTask(task: 'cooperative-search');
      expect(definition.observationSpec.hash, profile.spec.hash);
      expect(definition.createActions().spec.hash, profile.decoder.spec.hash);
      expect(definition.artifactFamily, profile.artifactFamily);
      expect(definition.registeredRole, -1);
      (route.single as List<num>)[0] = 99;
      expect(definition.authoredRoute.single.x, 2);
      expect(() => definition.authoredRoute.clear(), throwsUnsupportedError);
      final references = GameAiAuthoringCodec().localReferences({
        'profile': 'guard',
        'brain': 'scripted',
        'multiTask': 'cooperative-search',
        'teamId': 'search-team',
        'multiRole': 'scout',
        'goalEntityId': 'goal',
      }).toList();
      expect(references.single.targetId, 'goal');
      expect(references.single.path, ['goalEntityId']);
    },
  );
  test(
    'multi task metadata rejects mismatched controllers, roles and routes',
    () {
      final base = <String, Object?>{
        'profile': 'guard',
        'brain': 'scripted',
        'multiTask': 'competitive-pursuit',
        'teamId': 'pursuit',
        'multiRole': 'pursuer',
      };
      expect(GameAiAuthoringDefinition(base).registeredRole, 1);
      expect(
        GameAiAuthoringDefinition({
          ...base,
          'multiRole': 'evader',
        }).registeredRole,
        -1,
      );
      for (final changes in <Map<String, Object?>>[
        {'profile': 'vehicle'},
        {'cameraMode': 'rgb'},
        {'multiTask': 'unknown'},
        {'multiRole': 'scout'},
        {'multiTask': null},
        {'teamId': null},
        {'multiRole': null},
        {'goalEntityId': 'unseen'},
        {
          'authoredRoute': List.filled(33, [0, 0, 0]),
        },
        {
          'authoredRoute': [
            [double.nan, 0, 0],
          ],
        },
        {
          'authoredRoute': [
            [100001, 0, 0],
          ],
        },
        {
          'authoredRoute': [
            [0, 0],
          ],
        },
        {'multiTask': 'cooperative-search', 'multiRole': 'scout'},
      ]) {
        expect(
          () => GameAiAuthoringDefinition({...base, ...changes}),
          throwsArgumentError,
          reason: changes.toString(),
        );
      }
    },
  );
  test('multi authored goal remaps through the existing spawn template', () {
    final registry = GameRegistry();
    registerGameAiCodecs(registry);
    final template = GameSpawnTemplate(
      id: 'search',
      registry: registry,
      entities: [
        GameEntityRecord(id: 'goal', nodeId: 'goal', components: []),
        GameEntityRecord(
          id: 'scout',
          nodeId: 'scout',
          components: [
            GameComponentRecord('game.ai', 1, {
              'profile': 'guard',
              'brain': 'scripted',
              'multiTask': 'cooperative-search',
              'teamId': 'search-team',
              'multiRole': 'scout',
              'goalEntityId': 'goal',
            }),
          ],
        ),
      ],
    );
    final instances = template.instantiate('second-team');
    final actor = instances.singleWhere((entity) => entity.nodeId == 'scout');
    final definition =
        template.construct(actor).single as GameAiAuthoringDefinition;
    expect(definition.goalEntityId, 'second-team/goal');
    expect(definition.registeredRole, 1);
  });
}
