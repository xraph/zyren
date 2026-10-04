import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game/authored.dart';

class World implements GameAuthoredWorld {
  @override
  bool inReach(GameEntityHandle actor, GameEntityHandle target) => true;
  @override
  bool within(GameEntityHandle actor, String target, double distance) => true;
  @override
  bool controlling(GameEntityHandle actor, String target) => false;
  @override
  bool possess(GameEntityHandle actor, GameEntityHandle target) => false;
  @override
  bool setActive(
    GameEntityHandle actor,
    GameEntityHandle target,
    bool active,
  ) => true;
}

class Running extends GameRuleAction {
  int ticks = 0, cancellations = 0;
  @override
  BehaviorStatus tick(BehaviorContext context) {
    ticks++;
    return BehaviorStatus.running;
  }

  @override
  void cancel(BehaviorContext context) {
    cancellations++;
  }
}

class Fixture {
  final library = GameRuleLibrary(), records = <String, GameEntityRecord>{};
  final actions = <Running>[];
  late final GameAuthoredGameplay authored;
  late final GameSession session;
  Fixture() {
    library.actions.register(
      'test.running',
      factory: (_) {
        final a = Running();
        actions.add(a);
        return a;
      },
    );
    final registry = GameRegistry();
    registerGameComponentCodecs(registry);
    registry.registerComponent(
      GameRuleComponentCodec(library.actions, library.predicates),
    );
    registry.registerComponent(
      GameStateMachineComponentCodec(library.actions, library.predicates),
    );
    final rule = GameRuleDefinition(
      graph: GameRuleGraph(
        root: 'run',
        nodes: [GameRuleNode.action('run', 'test.running')],
      ),
    ).toJson();
    records['player'] = GameEntityRecord(
      id: 'player',
      components: [
        GameComponentRecord(
          'game.inventory',
          1,
          Inventory(capacity: 10, items: {'key': 1}).toJson(),
        ),
        GameComponentRecord('game.rules', 1, rule),
        GameComponentRecord(
          'game.state-machine',
          1,
          GameStateMachineDefinition(
            initial: 'idle',
            states: {'idle': GameRuleDefinition.fromJson(rule)},
            transitions: [],
          ).toJson(),
        ),
      ],
    );
    records['pooled'] = GameEntityRecord(
      id: 'pooled',
      components: [
        GameComponentRecord(
          'game.inventory',
          1,
          Inventory(capacity: 10, items: {'coin': 2}).toJson(),
        ),
        GameComponentRecord(
          'game.interaction',
          1,
          GameInteractionDefinition(id: 'pooled-use').toJson(),
        ),
        GameComponentRecord('game.rules', 1, rule),
      ],
    );
    authored = GameAuthoredGameplay(
      library: library,
      world: World(),
      entityDefinition: (id) => records[id],
    );
    session = GameSession(
      project: CompiledGameProject(
        project: GameProject(
          id: 'topology',
          startupLevel: 'main',
          registry: registry,
          levels: [
            GameLevel(
              id: 'main',
              scene: GameSceneIdentity('scene', '1'),
              entities: [records['player']!],
            ),
          ],
        ),
      ),
      seed: 7,
      systems: [authored],
    )..step();
  }
  GameEntityHandle get player => session.entities.entities
      .singleWhere((e) => e.handle.id == 'player')
      .handle;
  GameEntityHandle spawn() => session.entities.spawn(
    'pooled',
    components: records['pooled']!.components,
  );
}

void main() {
  test(
    'authored topology preserves surviving inventory and running action ownership',
    () async {
      final f = Fixture();
      try {
        final originalRules = f.authored.gameplay.actor(f.player)!;
        originalRules.inventory.add('key', 1);
        final action = f.actions.first, machineAction = f.actions.last;
        final spawned = f.spawn();
        f.authored.reconcile();
        f.session.step();
        expect(f.authored.gameplay.actor(f.player), same(originalRules));
        expect(f.authored.hasItem(f.player, 'key', 2), isTrue);
        expect(f.actions.first, same(action));
        expect(action.ticks, 2);
        expect(action.cancellations, 0);
        expect(machineAction.ticks, 2);
        expect(machineAction.cancellations, 0);
        expect(f.authored.states[f.player], 'idle');
        expect(f.authored.hasItem(spawned, 'coin', 2), isTrue);
        expect(f.authored.interact(f.player, 'pooled-use'), isTrue);
        f.session.step();
        expect(f.authored.interactionApplied(f.player, 'pooled-use'), isTrue);
        f.session.entities.despawn(spawned);
        f.authored.reconcile();
        expect(f.authored.gameplay.actor(spawned), isNull);
        expect(f.authored.interact(f.player, 'pooled-use'), isFalse);
        expect(action.cancellations, 0);
        final fresh = f.spawn();
        f.authored.reconcile();
        expect(fresh, isNot(spawned));
        expect(f.authored.hasItem(fresh, 'coin', 2), isTrue);
        expect(f.authored.gameplay.actor(f.player), same(originalRules));
      } finally {
        await f.session.close();
      }
    },
  );
  test(
    'authored restore prepares known dormant recipes and drops absent pooled definitions',
    () async {
      final f = Fixture();
      try {
        final initial = f.player;
        final pooled = f.spawn();
        f.authored.reconcile();
        f.session.step();
        f.authored.gameplay.actor(pooled)!.inventory.add('coin', 1);
        f.session.pause();
        final save = f.session.save();
        f.session.entities.despawn(pooled);
        f.authored.reconcile();
        f.session.restore(save);
        final fresh = f.session.entities.entities
            .singleWhere((e) => e.handle.id == 'pooled')
            .handle;
        expect(fresh, isNot(pooled));
        expect(f.authored.hasItem(fresh, 'coin', 3), isTrue);
        expect(f.authored.gameplay.interactions['pooled-use']!.target, fresh);
        expect(f.authored.gameplay.actor(initial), isNull);
        f.session.entities.despawn(fresh);
        f.authored.reconcile();
        final absent = f.session.save();
        final again = f.spawn();
        f.authored.reconcile();
        f.session.restore(absent);
        expect(f.session.entities.isAlive(again), isFalse);
        expect(f.authored.gameplay.interactions, isEmpty);
      } finally {
        await f.session.close();
      }
    },
  );
  test(
    'duplicate interaction reconciliation fails before changing survivor state',
    () async {
      final f = Fixture();
      try {
        f.spawn();
        f.authored.reconcile();
        final original = f.authored.gameplay.actor(f.player),
            interactions = f.authored.gameplay.interactions;
        f.session.entities.spawn(
          'duplicate',
          components: f.records['pooled']!.components,
        );
        expect(f.authored.reconcile, throwsStateError);
        expect(f.authored.gameplay.actor(f.player), same(original));
        expect(f.authored.gameplay.interactions, interactions);
        expect(f.actions.first.cancellations, 0);
      } finally {
        await f.session.close();
      }
    },
  );
}
