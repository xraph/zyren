import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_game_native/test/runtime_test.dart' as fixture;

final class RuntimeFixture {
  final Scene scene = Scene();
  final Camera camera = PerspectiveCamera();
  late final GameLevelRuntime runtime;
  late final GameLevelAi ai;
  late final MlModelCache cache;
  SceneEngine? engine;
  RuntimeFixture({
    String brain = 'scripted',
    bool occluded = false,
    int actorCount = 1,
    bool includePolicy = true,
  }) {
    final registry = GameRegistry();
    registerGameComponentCodecs(registry);
    registerGameLevelCodecs(registry);
    registerGameAiCodecs(registry);
    final level = fixture.project().levels.single;
    final model = MlModelManifest.decode(
      File('test/fixtures/runtime_probe.json').readAsStringSync(),
    );
    final compiled = CompiledGameProject(
      project: GameProject(
        id: 'ai-native-fixture',
        startupLevel: 'main',
        registry: registry,
        levels: [
          GameLevel(
            id: 'main',
            scene: level.scene,
            entities: [
              ...level.entities,
              for (var i = 0; i < actorCount; i++)
                GameEntityRecord(
                  id: actorCount == 1 ? 'npc' : 'npc$i',
                  nodeId: actorCount == 1 ? 'npc' : 'npc$i',
                  components: [
                    ...level.entities.last.components.where(
                      (c) => c.type != 'game.input' && c.type != 'game.camera',
                    ),
                    GameComponentRecord('game.ai', 1, {
                      'profile': 'guard',
                      'brain': brain,
                      if (brain != 'scripted') 'modelHash': model.sha256,
                    }),
                  ],
                ),
              if (occluded)
                GameEntityRecord(
                  id: 'wall',
                  nodeId: 'wall',
                  components: [
                    GameComponentRecord(
                      'game.collider',
                      1,
                      GameColliderDefinition(
                        halfExtents: const Vec3(3, 3, .2),
                      ).toJson(),
                    ),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
    final objects = fixture.objects(scene);
    objects['player']!.position = const Vec3(0, 1.5, 3);
    for (var i = 0; i < actorCount; i++) {
      objects[actorCount == 1 ? 'npc' : 'npc$i'] = scene.add(
        Group()..position = Vec3((i % 12) * 2.0, 1.5, (i ~/ 12) * -2.0),
      );
    }
    if (occluded) {
      objects['wall'] = scene.add(Group()..position = const Vec3(0, 1, 1.5));
    }
    cache = MlModelCache(
      resolver: (_) => File('test/fixtures/runtime_probe.onnx').readAsBytes(),
    );
    ai = GameLevelAi(
      runtime: () => runtime,
      cache: cache,
      policies: {
        if (brain != 'scripted' && includePolicy)
          model.sha256: GameRuntimePolicy(
            contract: PolicyContract(
              model: model,
              observation: TrainingProfiles.guard().spec,
              decoder: ActionDecoder.characterDiscrete(),
              continuousOutput: null,
              discreteOutput: 'logits',
            ),
            fixedHz: compiled.fixedHz,
            evaluationHash: '0' * 64,
          ),
      },
    );
    runtime = GameLevelRuntime(
      project: compiled,
      scene: scene,
      camera: camera,
      objects: objects,
      systemFactory: (_) => ai.systems,
    );
  }
  Future<void> start() async {
    await runtime.initialize();
    await ai.warmup();
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => fixture.RuntimeRenderer(),
      plugins: runtime.plugins,
    );
    await step();
  }

  Future<void> step() async {
    runtime.simulation!.step();
    await ai.flush();
  }

  GameEntityHandle get npc => ai.actors.single;
  Future<void> close() async {
    await engine?.dispose();
    await ai.close();
    await runtime.close();
  }
}

void main() {
  test(
    'inactive targets produce no fresh visual facts and resume when activated',
    () async {
      final f = RuntimeFixture();
      try {
        await f.start();
        final player = f.runtime.inputActor!;
        var beliefs = f.ai.inspect(f.npc)['beliefs'] as List;
        expect(beliefs.any((b) => (b as Map)['source'] == 'visible'), isTrue);
        final observed = beliefs
            .map((b) => (b as Map)['observedTick'] as int)
            .reduce((a, b) => a > b ? a : b);
        f.runtime.setEntityActive(player, false);
        await f.step();
        beliefs = f.ai.inspect(f.npc)['beliefs'] as List;
        expect(
          beliefs.every((b) => (b as Map)['observedTick'] <= observed),
          isTrue,
        );
        f.runtime.setEntityActive(player, true);
        await f.step();
        beliefs = f.ai.inspect(f.npc)['beliefs'] as List;
        expect(
          beliefs.any((b) => (b as Map)['observedTick'] > observed),
          isTrue,
        );
      } finally {
        await f.close();
      }
    },
  );

  test('actor and request admission keep a fixed upper bound', () async {
    final f = RuntimeFixture();
    await f.start();
    try {
      final ml = MlScheduler(cache: f.cache, currentTick: () => 0);
      expect(
        () => MlScheduler(
          cache: f.cache,
          currentTick: () => 0,
          maxQueuedRequests: 257,
        ),
        throwsArgumentError,
      );
      expect(
        () => PolicyGroup(
          episodeId: 'limit',
          entities: f.runtime.simulation!.session.entities,
          ml: ml,
          maxActors: 257,
        ),
        throwsArgumentError,
      );
      await ml.close();
    } finally {
      await f.close();
    }
  });

  test(
    '144 learned actors share weights across bounded native batches and keep private state',
    () async {
      final f = RuntimeFixture(brain: 'learned', actorCount: 144);
      try {
        await f.start();
        await f.step();
        await f.step();
        expect(f.ai.actors, hasLength(144));
        expect(f.ai.group!.modelCount, 1);
        final counts = f.ai.actors
            .map((a) => f.ai.group!.stateFor(a)!.version)
            .toSet();
        expect(counts, {2});
        final others = f.ai.actors
            .skip(1)
            .map((a) => f.ai.group!.stateFor(a)!.snapshot().encode())
            .toList();
        f.ai.group!.reset(f.ai.actors.first);
        expect(f.ai.group!.stateFor(f.ai.actors.first)!.version, 0);
        expect(
          f.ai.actors
              .skip(1)
              .map((a) => f.ai.group!.stateFor(a)!.snapshot().encode())
              .toList(),
          others,
        );
        expect((await f.cache.worker.diagnostics()).liveSessions, 1);
      } finally {
        await f.close();
      }
      expect((await f.cache.worker.diagnostics()).liveSessions, 0);
    },
  );

  test(
    'only an authored hybrid fallback can start without its model',
    () async {
      final hybrid = RuntimeFixture(brain: 'hybrid', includePolicy: false);
      try {
        await hybrid.start();
        await hybrid.step();
        expect(hybrid.ai.inspect(hybrid.npc)['activeBrain'], 'scripted');
        expect(hybrid.ai.inspect(hybrid.npc)['modelFailure'], isNotNull);
        expect(hybrid.ai.fallbackTicks, greaterThan(0));
      } finally {
        await hybrid.close();
      }
      final learned = RuntimeFixture(brain: 'learned', includePolicy: false);
      await learned.runtime.initialize();
      await expectLater(learned.ai.warmup(), throwsStateError);
      await learned.close();
    },
  );

  test(
    'scripted native perception obeys walls and retains approximate hearing',
    () async {
      final f = RuntimeFixture(occluded: true);
      try {
        await f.start();
        expect(f.ai.inspect(f.npc)['beliefs'], isEmpty);
        final before = f.runtime.resolveBody(f.npc)!.state.pose.position;
        for (var i = 0; i < 4; i++) {
          await f.step();
        }
        expect(
          f.runtime.resolveBody(f.npc)!.state.pose.position.z,
          closeTo(before.z, .001),
        );
        GameSoundPublisher(f.runtime.simulation!.session).emit(
          GameSoundEvent(
            id: 'step',
            category: 'footstep',
            tick: f.runtime.tick,
            position: const Vec3(0, 1.5, 3),
            loudness: 1,
            range: 10,
            sourceEntityId: 'player',
          ),
        );
        await f.step();
        final beliefs = f.ai.inspect(f.npc)['beliefs'] as List;
        expect(beliefs, isNotEmpty);
        expect(beliefs.every((b) => (b as Map)['source'] == 'audible'), isTrue);
        expect(beliefs.every((b) => !(b as Map).containsKey('target')), isTrue);
        final save = await f.ai.save();
        final old = f.npc;
        await f.ai.restore(save);
        expect(f.npc, isNot(old));
        expect(f.ai.inspect(f.npc)['beliefs'], beliefs);
        expect(() => f.ai.inspect(old), throwsStateError);
      } finally {
        await f.close();
      }
      expect(f.cache.diagnostics.residentModels, 0);
    },
  );

  test(
    'native learned actor commits recurrent state across pause and fresh-handle restore',
    () async {
      final f = RuntimeFixture(brain: 'learned');
      try {
        await f.start();
        for (var i = 0; i < 5; i++) {
          await f.step();
        }
        final old = f.npc;
        final brain = f.ai.group!.brainFor(old)!;
        expect(brain.state.version, greaterThan(0));
        expect(
          f.runtime.resolveBody(old)!.state.pose.position.z,
          greaterThan(.1),
        );
        final save = await f.ai.save();
        final state = brain.state.snapshot().encode();
        final position = f.runtime.resolveBody(old)!.state.pose.position;
        f.runtime.resume();
        await f.step(); // New sensor frame after suspension.
        await f.step(); // Apply its completed action.
        final nextState = brain.state.snapshot().encode();
        expect(nextState, isNot(state));
        await f.ai.restore(GameSave.decode(save.encode()));
        final fresh = f.npc;
        expect(fresh, isNot(old));
        expect(f.ai.group!.brainFor(fresh)!.state.snapshot().encode(), state);
        expect(f.runtime.resolveBody(fresh)!.state.pose.position, position);
        f.runtime.resume();
        await f.step();
        await f.step();
        expect(
          f.ai.group!.brainFor(fresh)!.state.snapshot().encode(),
          nextState,
        );
        expect(f.runtime.acquireActorControl(fresh), isNull);
        final current = await f.ai.save();
        final malformed = jsonDecode(current.encode()) as Map<String, dynamic>;
        (malformed['state']['game.ai.runtime'] as Map)['tick'] =
            current.tick + 1;
        expect(
          () => f.runtime.restore(GameSave.decode(jsonEncode(malformed))),
          throwsA(anything),
        );
        expect(f.npc, fresh);
        expect(f.runtime.error, isNull);
        expect(f.runtime.save().encode(), current.encode());
      } finally {
        await f.close();
      }
      expect((await f.cache.worker.diagnostics()).liveSessions, 0);
    },
  );

  test(
    'hybrid checkpoint restores the active learned child without resetting it',
    () async {
      final f = RuntimeFixture(brain: 'hybrid');
      try {
        await f.start();
        for (var i = 0; i < 5; i++) {
          await f.step();
        }
        final state = f.ai.group!.stateFor(f.npc)!.snapshot().encode();
        final save = await f.ai.save();
        await f.ai.restore(save);
        expect(f.ai.group!.stateFor(f.npc)!.snapshot().encode(), state);
        f.runtime.resume();
        await f.step();
        expect(f.ai.group!.stateFor(f.npc)!.snapshot().encode(), state);
        await f.step();
        expect(f.ai.group!.stateFor(f.npc)!.snapshot().encode(), isNot(state));
      } finally {
        await f.close();
      }
    },
  );

  test(
    'closing during warmup drains acquired models before releasing cache',
    () async {
      final f = RuntimeFixture(brain: 'learned');
      await f.runtime.initialize();
      final warming = f.ai.warmup();
      final expected = expectLater(warming, throwsStateError);
      await f.ai.close();
      await expected;
      await f.runtime.close();
      expect(f.cache.diagnostics.residentModels, 0);
      expect((await f.cache.worker.diagnostics()).liveSessions, 0);
    },
  );
}
