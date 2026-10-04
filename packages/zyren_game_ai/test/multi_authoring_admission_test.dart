import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_ml/zyren_ml.dart';

GameEntityRecord multiActor(
  String id,
  String role, {
  String task = 'competitive-pursuit',
  String brain = 'scripted',
  String? goal,
  String team = 'team',
  List<List<double>> route = const [],
}) => GameEntityRecord(
  id: id,
  nodeId: id,
  components: [
    GameComponentRecord(
      'game.collider',
      1,
      GameColliderDefinition(
        shape: GameColliderShape.capsule,
        motion: GameBodyMotion.kinematic,
      ).toJson(),
    ),
    GameComponentRecord(
      'game.character',
      1,
      GameCharacterDefinition(maxSpeed: 2).toJson(),
    ),
    GameComponentRecord('game.ai', 1, {
      'profile': 'guard',
      'brain': brain,
      'multiTask': task,
      'multiRole': role,
      'teamId': team,
      'goalEntityId': ?goal,
      if (brain != 'scripted') 'modelHash': '0' * 64,
      if (route.isNotEmpty) 'authoredRoute': route,
    }),
  ],
);
GameEntityRecord multiGoal(String id) => GameEntityRecord(
  id: id,
  nodeId: id,
  components: [
    GameComponentRecord(
      'game.collider',
      1,
      GameColliderDefinition(halfExtents: const Vec3(.2, .2, .2)).toJson(),
    ),
  ],
);

final class AdmissionFixture {
  late final GameLevelRuntime runtime;
  late final GameLevelAi ai;
  int resolved = 0;
  AdmissionFixture(
    List<GameEntityRecord> entities, {
    int fixedHz = 50,
    Map<String, GameRuntimePolicy> policies = const {},
  }) {
    final registry = GameRegistry();
    registerGameComponentCodecs(registry);
    registerGameLevelCodecs(registry);
    registerGameAiCodecs(registry);
    final project = CompiledGameProject(
      project: GameProject(
        id: 'multi-admission',
        startupLevel: 'arena',
        registry: registry,
        levels: [
          GameLevel(
            id: 'arena',
            scene: GameSceneIdentity('arena', '1'),
            entities: entities,
          ),
        ],
      ),
      systemVersions: {},
      fixedHz: fixedHz,
    );
    runtime = GameLevelRuntime(
      project: project,
      scene: Scene(),
      camera: PerspectiveCamera(),
      objects: {},
    );
    final cache = MlModelCache(
      resolver: (_) async {
        resolved++;
        throw StateError('Admission must precede model resolution.');
      },
    );
    ai = GameLevelAi(runtime: () => runtime, cache: cache, policies: policies);
  }
  Future<void> close() async {
    await ai.close();
    await runtime.close();
  }
}

void main() {
  test(
    'handcrafted multi contract cannot bypass accepted artifact admission',
    () async {
      final profile = TrainingMultiProfiles.forTask(
        task: 'competitive-pursuit',
      );
      final data =
          jsonDecode(
                File('test/fixtures/runtime_probe.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      data['sha256'] = '0' * 64;
      final input = (data['inputs'] as List).first as Map;
      (input['shape'] as List)[1] = profile.spec.width;
      (input['maxShape'] as List)[1] = profile.spec.width;
      data['preprocessing'] = {'multiProfile': profile.toJson()};
      final model = MlModelManifest.decode(jsonEncode(data));
      final raw = GameRuntimePolicy(
        contract: PolicyContract(
          model: model,
          observation: profile.spec,
          decoder: profile.decoder,
          continuousOutput: null,
          discreteOutput: 'logits',
        ),
        fixedHz: 50,
        evaluationHash: '0' * 64,
      );
      final f = AdmissionFixture(
        [
          multiActor('p', 'pursuer', brain: 'learned'),
          multiActor('e', 'evader', brain: 'learned'),
        ],
        policies: {model.sha256: raw},
      );
      try {
        await expectLater(f.ai.warmup(), throwsStateError);
        expect(f.resolved, 0);
        expect(f.runtime.world, isNull);
      } finally {
        await f.close();
      }
    },
  );
  test('registered team clock is checked before model preparation', () async {
    final f = AdmissionFixture([
      multiActor('p', 'pursuer'),
      multiActor('e', 'evader'),
    ], fixedHz: 60);
    try {
      await expectLater(f.ai.warmup(), throwsStateError);
      expect(f.resolved, 0);
    } finally {
      await f.close();
    }
  });
  test(
    'registered scripted teams preflight without allocating native models',
    () async {
      for (final entities in [
        [multiActor('p', 'pursuer'), multiActor('e', 'evader')],
        [
          multiActor('s', 'scout', task: 'cooperative-search', goal: 'goal'),
          multiActor('r', 'searcher', task: 'cooperative-search', goal: 'goal'),
          multiGoal('goal'),
        ],
      ]) {
        final f = AdmissionFixture(entities);
        try {
          await f.ai.warmup();
          expect(f.resolved, 0);
          expect(f.ai.actors, isEmpty);
          expect(f.runtime.world, isNull);
        } finally {
          await f.close();
        }
      }
    },
  );
  test(
    'missing roles, foreign goals and differing team goals reject before owners',
    () async {
      for (final entities in [
        [multiActor('p', 'pursuer')],
        [multiActor('p', 'pursuer'), multiActor('q', 'pursuer')],
        [
          multiActor(
            'p',
            'pursuer',
            route: [
              [1, 0, 0],
            ],
          ),
          multiActor('e', 'evader'),
        ],
        [
          multiActor('s', 'scout', task: 'cooperative-search', goal: 'one'),
          multiActor('r', 'searcher', task: 'cooperative-search', goal: 'two'),
          multiGoal('one'),
          multiGoal('two'),
        ],
      ]) {
        final f = AdmissionFixture(entities);
        try {
          await expectLater(f.ai.warmup(), throwsStateError);
          expect(f.resolved, 0);
          expect(f.ai.actors, isEmpty);
          expect(f.runtime.world, isNull);
        } finally {
          await f.close();
        }
      }
    },
  );
  test('dangling authored goals reject at the shared project registry', () {
    expect(
      () => AdmissionFixture([
        multiActor('s', 'scout', task: 'cooperative-search', goal: 'missing'),
      ]),
      throwsFormatException,
    );
  });
  test(
    'learned multi launch stays closed without an accepted artifact',
    () async {
      final f = AdmissionFixture([
        multiActor('p', 'pursuer', brain: 'learned'),
        multiActor('e', 'evader', brain: 'learned'),
      ]);
      try {
        await expectLater(f.ai.warmup(), throwsStateError);
        expect(f.resolved, 0);
        expect(f.runtime.world, isNull);
      } finally {
        await f.close();
      }
    },
  );
}
