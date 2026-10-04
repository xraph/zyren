import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_game_native/test/runtime_test.dart' as render;
import 'multi_authoring_admission_test.dart' as admission;

List<GameEntityRecord> searchTeam() => [
  admission.multiActor(
    'scout',
    'scout',
    task: 'cooperative-search',
    goal: 'goal',
  ),
  admission.multiActor(
    'searcher',
    'searcher',
    task: 'cooperative-search',
    goal: 'goal',
  ),
  admission.multiGoal('goal'),
];

final class MultiRuntimeFixture {
  final scene = Scene(), camera = PerspectiveCamera();
  late final GameLevelRuntime runtime;
  late final GameLevelAi ai;
  SceneEngine? engine;
  MultiRuntimeFixture({
    bool pooled = false,
    bool competitive = false,
    bool renamed = false,
    bool secondTeam = false,
  }) {
    final registry = GameRegistry();
    registerGameComponentCodecs(registry);
    registerGameLevelCodecs(registry);
    registerGameAiCodecs(registry);
    final entities = [
      GameEntityRecord(
        id: 'ground',
        nodeId: 'ground',
        components: [
          GameComponentRecord(
            'game.collider',
            1,
            GameColliderDefinition(
              halfExtents: const Vec3(15, .5, 15),
            ).toJson(),
          ),
        ],
      ),
      if (!pooled)
        ...(competitive
            ? [
                admission.multiActor('pursuer', 'pursuer'),
                admission.multiActor(
                  'evader',
                  'evader',
                  route: [
                    [4, 1.5, 0],
                    [4, 1.5, 3],
                  ],
                ),
              ]
            : searchTeam()),
      if (secondTeam) ...[
        admission.multiActor('foreign-pursuer', 'pursuer', team: 'foreign'),
        admission.multiActor('foreign-evader', 'evader', team: 'foreign'),
      ],
      GameEntityRecord(
        id: 'wall',
        nodeId: 'wall',
        components: [
          GameComponentRecord(
            'game.collider',
            1,
            GameColliderDefinition(halfExtents: const Vec3(.3, 3, .3)).toJson(),
          ),
        ],
      ),
    ];
    final authored = [
      for (final record in entities)
        if (renamed && record.id == 'goal')
          admission.multiGoal('zz-goal')
        else if (renamed && record.components.any((c) => c.type == 'game.ai'))
          GameEntityRecord(
            id: record.id,
            nodeId: record.nodeId,
            components: [
              for (final c in record.components)
                if (c.type == 'game.ai')
                  GameComponentRecord(c.type, c.version, {
                    ...c.data,
                    'goalEntityId': 'zz-goal',
                  })
                else
                  c,
            ],
          )
        else
          record,
    ];
    final project = CompiledGameProject(
      project: GameProject(
        id: 'multi-runtime',
        startupLevel: 'arena',
        registry: registry,
        levels: [
          GameLevel(
            id: 'arena',
            scene: GameSceneIdentity('arena', '1'),
            entities: authored,
          ),
        ],
      ),
      fixedHz: 50,
    );
    final objects = {
      for (final e in authored)
        e.nodeId!: scene.add(Group()..position = position(e.id)),
    };
    ai = GameLevelAi(
      runtime: () => runtime,
      cache: MlModelCache(
        resolver: (_) async =>
            throw StateError('Scripted team must not load a model.'),
      ),
    );
    runtime = GameLevelRuntime(
      project: project,
      scene: scene,
      camera: camera,
      objects: objects,
      systemFactory: (_) => ai.systems,
    );
  }
  Vec3 position(String id) => switch (id.split(RegExp(r'[./]')).last) {
    'scout' || 'pursuer' => const Vec3(0, 1.5, 0),
    'searcher' || 'evader' => const Vec3(4, 1.5, 0),
    'goal' || 'zz-goal' => const Vec3(0, 1.5, 4),
    'wall' => const Vec3(2, 1.5, 2),
    _ => Vec3.zero,
  };
  Future<void> start() async {
    await runtime.initialize();
    await ai.warmup();
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => render.RuntimeRenderer(),
      plugins: runtime.plugins,
    );
  }

  Future<void> step() async {
    runtime.simulation!.step();
    await ai.flush();
  }

  GameEntityHandle actor(String role) =>
      ai.actors.singleWhere((h) => ai.inspect(h)['multiRole'] == role);
  List<double> extra(String role) => ai
      .observation(actor(role))!
      .tensor
      .float32Values
      .skip(
        TrainingMultiProfiles.forTask(
          task: 'cooperative-search',
        ).assembler.spec.width,
      )
      .toList();
  Future<void> close() async {
    await engine?.dispose();
    await ai.close();
    await runtime.close();
  }
}

void main() {
  test(
    'team snapshots reuse the captured pose and exclude foreign catalog members',
    () async {
      final f = MultiRuntimeFixture(secondTeam: true);
      try {
        await f.start();
        for (var tick = 0; tick < 3; tick++) {
          await f.step();
        }
        for (final actor in f.ai.actors) {
          final frame = f.ai.observation(actor)!,
              state = f.runtime.resolveBody(actor)!.state;
          final q = state.pose.rotation;
          final velocity = Quat(-q.x, -q.y, -q.z, q.w).rotate(state.velocity);
          expect(frame.tick, f.runtime.simulation!.session.tick);
          for (var axis = 0; axis < 3; axis++) {
            expect(
              frame.readings.first.values[axis],
              closeTo(velocity.storage[axis], 1e-6),
            );
          }
          final foreign = f.ai.inspect(actor)['teamId'] == 'foreign';
          expect(
            frame.visibleIds.every(
              (id) => foreign
                  ? id.startsWith('foreign-')
                  : !id.startsWith('foreign-'),
            ),
            true,
          );
        }
      } finally {
        await f.close();
      }
    },
  );
  test(
    'retiring a required role suspends its team and cancels delayed delivery',
    () async {
      final f = MultiRuntimeFixture();
      try {
        await f.start();
        for (var tick = 0; tick < 5; tick++) {
          await f.step();
        }
        final searcher = f.actor('searcher'), scout = f.actor('scout');
        final before = f.runtime.resolveBody(scout)!.state.pose.position;
        f.runtime.setEntityActive(searcher, false);
        await f.step();
        expect(f.ai.inspect(scout)['pendingTeamMessages'], 0);
        expect(
          f.runtime.resolveBody(scout)!.state.pose.position.x,
          closeTo(before.x, 1e-6),
        );
        f.runtime.setEntityActive(searcher, true);
        await f.step();
        await f.step();
        expect(f.ai.inspect(searcher)['receivedObservationTick'], isNull);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'renamed goal identity retains permitted message provenance across slot reorder',
    () async {
      final original = MultiRuntimeFixture(),
          renamed = MultiRuntimeFixture(renamed: true);
      try {
        await original.start();
        await renamed.start();
        for (var tick = 0; tick < 7; tick++) {
          await original.step();
          await renamed.step();
        }
        final a = original.ai.observation(original.actor('scout'))!;
        final b = renamed.ai.observation(renamed.actor('scout'))!;
        expect(a.entities.first!.handle.id, 'goal');
        expect(b.entities.first!.handle.id, 'searcher');
        expect(original.extra('searcher'), renamed.extra('searcher'));
        expect(
          renamed.ai.inspect(
            renamed.actor('searcher'),
          )['receivedObservationTick'],
          5,
        );
        expect(renamed.extra('searcher')[8], 1);
        // Base visible-slot packing is identity ordered. This proves host goal
        // provenance, not invariant neural behavior across these two tensors.
        expect(a.tensor.float32Values, isNot(b.tensor.float32Values));
      } finally {
        await original.close();
        await renamed.close();
      }
    },
  );
  test(
    'competitive roles use their registered route and no message planes',
    () async {
      final f = MultiRuntimeFixture(competitive: true);
      try {
        await f.start();
        await f.step();
        final profile = TrainingMultiProfiles.forTask(
          task: 'competitive-pursuit',
        );
        expect(
          f.ai.observation(f.actor('evader'))!.schemaHash,
          profile.spec.hash,
        );
        expect(f.ai.inspect(f.actor('evader'))['routeIndex'], 1);
        expect(f.extra('evader')[0], -1);
        expect(f.extra('evader')[3], 1);
        for (var tick = 0; tick < 12; tick++) {
          await f.step();
          expect(f.extra('evader').skip(4), List.filled(6, 0));
          expect(f.extra('pursuer').skip(4), List.filled(6, 0));
          expect(f.ai.inspect(f.actor('pursuer'))['pendingTeamMessages'], 0);
        }
      } finally {
        await f.close();
      }
    },
  );
  test(
    'real Rapier goal visibility sends only delayed permitted team observations',
    () async {
      final f = MultiRuntimeFixture();
      try {
        await f.start();
        for (var i = 0; i < 5; i++) {
          await f.step();
        }
        expect(
          f.ai.observation(f.actor('scout'))!.visibleIds,
          contains('goal'),
        );
        expect(
          f.ai.observation(f.actor('searcher'))!.visibleIds,
          isNot(contains('goal')),
        );
        expect(f.extra('searcher').skip(4), List.filled(6, 0));
        expect(f.ai.inspect(f.actor('searcher'))['pendingTeamMessages'], 1);
        await f.step();
        expect(f.extra('searcher').skip(4), List.filled(6, 0));
        await f.step();
        expect(f.extra('searcher')[8], 1);
        expect(f.extra('searcher')[9], 1);
        expect(f.ai.inspect(f.actor('searcher'))['receivedObservationTick'], 5);
        expect(
          f.ai.observation(f.actor('searcher'))!.schemaHash,
          TrainingMultiProfiles.forTask(task: 'cooperative-search').spec.hash,
        );
        expect(f.ai.group!.modelCount, 0);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'pause cancels delayed messages and save restores committed history on fresh handles',
    () async {
      final f = MultiRuntimeFixture();
      try {
        await f.start();
        for (var i = 0; i < 5; i++) {
          await f.step();
        }
        f.runtime.pause();
        expect(f.ai.inspect(f.actor('searcher'))['pendingTeamMessages'], 0);
        f.runtime.resume();
        await f.step();
        await f.step();
        expect(f.extra('searcher').skip(4), List.filled(6, 0));
        for (var i = 0; i < 5; i++) {
          await f.step();
        }
        expect(f.extra('searcher')[8], 1);
        final old = f.actor('searcher'), saved = await f.ai.save();
        final encoded = jsonDecode(saved.encode()) as Map<String, dynamic>;
        final state = (encoded['state'] as Map)['game.ai.runtime'] as Map;
        final record = (state['actors'] as Map)['searcher'] as Map;
        (record['teamDefinition'] as Map)['role'] = 'scout';
        await expectLater(
          f.ai.restore(GameSave.decode(jsonEncode(encoded))),
          throwsFormatException,
        );
        expect(f.actor('searcher'), old);
        await f.ai.restore(saved);
        final fresh = f.actor('searcher');
        expect(fresh.generation, greaterThan(old.generation));
        expect(() => f.ai.observation(old), throwsStateError);
        expect(f.ai.inspect(fresh)['pendingTeamMessages'], 0);
        expect(f.ai.inspect(fresh)['receivedObservationTick'], 10);
        f.runtime.resume();
        await f.step();
        expect(f.extra('searcher')[8], 1);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'prepared team retirement and respawn never inherit old generation messages',
    () async {
      final f = MultiRuntimeFixture(pooled: true);
      try {
        await f.start();
        await f.step();
        final slot = await f.runtime.prepareSpawn(
          GameSpawnTemplate(
            id: 'search',
            registry: f.runtime.project.project.registry,
            entities: searchTeam(),
          ),
          instanceId: 'search',
          prepare: (records) async => GameRuntimeSpawnResources(
            objects: {
              for (final r in records)
                r.nodeId!: Group()..position = f.position(r.id),
            },
          ),
        );
        GameEntityHandle? old;
        for (var cycle = 0; cycle < 4; cycle++) {
          if (f.runtime.isPaused) f.runtime.resume();
          final admission = f.runtime.enqueueSpawn(slot);
          await f.step();
          expect(await admission, true);
          final fresh = f.actor('searcher');
          if (old != null) {
            expect(fresh.generation, greaterThan(old.generation));
          }
          for (var i = 0; i < 4; i++) {
            await f.step();
          }
          final saved = await f.ai.save();
          f.runtime.retireSpawn(slot);
          await f.ai.flush();
          expect(f.ai.actors, isEmpty);
          if (cycle == 3) {
            await f.ai.restore(saved);
            expect(f.ai.actors, hasLength(2));
          }
          old = fresh;
        }
      } finally {
        await f.close();
      }
    },
  );
}
