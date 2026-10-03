import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game/authored.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

final class World implements GameAuthoredWorld {
  bool reachable = true, nearCheckpoint = false;
  final active = <String, bool>{};
  String controlled = 'player';
  @override
  bool inReach(GameEntityHandle actor, GameEntityHandle target) => reachable;
  @override
  bool within(GameEntityHandle actor, String target, double distance) =>
      target == 'checkpoint' && nearCheckpoint;
  @override
  bool controlling(GameEntityHandle actor, String target) =>
      controlled == target;
  @override
  bool setActive(GameEntityHandle actor, GameEntityHandle target, bool value) {
    active[target.id] = value;
    return true;
  }

  @override
  bool possess(GameEntityHandle actor, GameEntityHandle target) {
    controlled = target.id;
    return true;
  }
}

Future<(GameSession, GameAuthoredGameplay, World)> create(
  GameTemplateKind kind,
) async {
  final library = GameRuleLibrary(),
      authoring = createGameDevelopmentAuthoring();
  final document = GameTemplate(
    kind,
    authoring,
  ).create(projectId: 'authored').document;
  final build =
      await GameProjectCompiler(
        registry: authoring.registry,
        assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
      ).compile(
        documents: [document],
        startupLevel: 'main',
        profile: GameBuildProfile(id: 'test'),
      );
  final world = World();
  final bound = GameAuthoredGameplay(library: library, world: world);
  final session = GameSession(
    project: build.artifact!.project,
    seed: 7,
    systems: [bound],
  )..step();
  return (session, bound, world);
}

void main() {
  test(
    'template key gate checkpoint and possession run through typed rules',
    () async {
      final (session, rules, world) = await create(
        GameTemplateKind.vehiclePlayground,
      );
      GameEntityHandle player() => session.entities.entities
          .singleWhere((e) => e.handle.id == 'player')
          .handle;
      void steps([int count = 10]) {
        for (var i = 0; i < count; i++) {
          session.step();
          session.events.drain();
        }
      }

      try {
        world.reachable = false;
        expect(rules.interact(player(), 'pickup-key'), isTrue);
        steps();
        expect(rules.hasItem(player(), 'key', 1), isFalse);
        world.reachable = true;
        expect(rules.interact(player(), 'pickup-key'), isTrue);
        steps();
        expect(rules.hasItem(player(), 'key', 1), isTrue);
        expect(rules.objectiveComplete(player(), 'key'), isTrue);
        expect(world.active['key'], isFalse);
        expect(rules.interact(player(), 'open-gate'), isTrue);
        steps();
        expect(rules.objectiveComplete(player(), 'gate'), isTrue);
        expect(world.active['gate'], isFalse);
        world.nearCheckpoint = true;
        steps();
        expect(rules.objectiveComplete(player(), 'checkpoint'), isTrue);
        expect(rules.interact(player(), 'enter-vehicle'), isTrue);
        steps();
        expect(world.controlled, 'vehicle');
        expect(rules.interactionApplied(player(), 'enter-vehicle'), isFalse);
        session.pause();
        final save = session.save(), old = player();
        session.restore(save);
        expect(player(), isNot(old));
        session.resume();
        steps();
        expect(rules.hasItem(player(), 'key', 1), isTrue);
        expect(rules.objectiveComplete(player(), 'checkpoint'), isTrue);
        expect(rules.interactionApplied(player(), 'open-gate'), isTrue);
      } finally {
        await session.close();
      }
    },
  );

  test(
    'collect rechecks reach at the mutation tick and queued saves are explicit',
    () async {
      final (session, rules, world) = await create(
        GameTemplateKind.exploration,
      );
      final actor = session.entities.entities
          .singleWhere((e) => e.handle.id == 'player')
          .handle;
      try {
        rules.interact(actor, 'pickup-key');
        expect(session.save, throwsStateError);
        session.step(); // interaction accepted, graph emits collect
        session.step(); // collect dispatched for next tick
        world.reachable = false;
        session.step(); // typed transfer checks current reach
        expect(rules.hasItem(actor, 'key', 1), isFalse);
        expect(
          rules.gameplay
              .actor(
                session.entities.entities
                    .singleWhere((e) => e.handle.id == 'key')
                    .handle,
              )!
              .inventory
              .count('key'),
          1,
        );
      } finally {
        await session.close();
      }
    },
  );
}
