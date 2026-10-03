import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'goal_test.dart' show context;
import 'memory_test.dart' show identity;

void main() {
  test(
    'custom typed skills use G6 services and bounded command queues',
    () async {
      final entities = GameEntityTable()..spawn('guard');
      final registry = GameSkillRegistry()..register(BurstSkill());
      expect(() => registry.register(BurstSkill()), throwsStateError);
      final brain = ScriptedBrain(
        identity: identity('guard'),
        entities: entities,
        skills: registry,
        actionCapacity: 1,
      );
      expect(
        () => brain.decide(context(1, [GameGoal(id: 'burst', skill: 'burst')])),
        throwsStateError,
      );
      await brain.close();
      await brain.close();
    },
  );
  test(
    'a foreign action schema is rejected before command execution',
    () async {
      final entities = GameEntityTable()..spawn('guard');
      final brain = ScriptedBrain(
        identity: identity('guard'),
        entities: entities,
      );
      expect(
        () => brain.decide(
          BrainContext(
            identity: identity('guard'),
            tick: 1,
            beliefs: [],
            goals: [],
            actionSpec: ScriptedBrain.driverActions,
          ),
        ),
        throwsArgumentError,
      );
      await brain.close();
    },
  );

  test(
    'registered G6 skills run and goal replacement cancels the running skill',
    () async {
      final entities = GameEntityTable()..spawn('guard');
      final cancelled = <SkillCancellation>[];
      final brain = ScriptedBrain(
        identity: identity('guard'),
        entities: entities,
        selector: UtilityGoalSelector(minCommitmentTicks: 0),
        onCancel: cancelled.add,
      );
      final route = GameGoal(
        id: 'route',
        skill: 'follow-route',
        route: [const Vec3(1, 0, -1)],
      );
      final first = brain.decide(context(1, [route]));
      expect(first.actions.single.action, 'ai.move');
      expect(first.actions.single.actor, identity('guard').entity);
      final next = brain.decide(
        context(2, [GameGoal(id: 'idle', skill: 'idle')]),
      );
      expect(next.actions.single.arguments['moveX'], 0);
      expect(cancelled.single.skillId, 'follow-route');
      expect(cancelled.single.reason, SkillCancelReason.goalChanged);
      await brain.close();
      await brain.close();
      expect(cancelled.length, 2);
      expect(() => brain.decide(context(3, [])), throwsStateError);
    },
  );
  test(
    'target generations are checked at goal choice and action application',
    () async {
      final entities = GameEntityTable();
      final actor = entities.spawn('guard'), target = entities.spawn('runner');
      final id = BrainIdentity(
        episodeId: 'ep',
        entity: actor,
        modelHash: 'script-v1',
      );
      final brain = ScriptedBrain(identity: id, entities: entities);
      brain.memory.observe(
        target: target,
        position: const Vec3(0, 0, -2),
        tick: 1,
      );
      BrainContext data(int tick, Set<GameEntityHandle> allowed) =>
          BrainContext(
            identity: id,
            tick: tick,
            beliefs: [],
            goals: [
              GameGoal(
                id: 'target',
                skill: 'investigate',
                target: target,
                beliefKey: 'entity:runner@${target.generation}',
              ),
            ],
            validTargets: allowed,
            actionSpec: context(1, []).actionSpec,
          );
      final decision = brain.decide(data(1, {target}));
      expect(decision.isApplicable(entities, id), isTrue);
      entities.despawn(target);
      final replacement = entities.spawn('runner');
      expect(decision.isApplicable(entities, id), isFalse);
      expect(brain.decide(data(2, {replacement})).goal, isNull);
      await brain.close();
    },
  );
  test(
    'reset cancels skills, clears memory and invalidates old context identity',
    () async {
      final entities = GameEntityTable()..spawn('guard');
      final brain = ScriptedBrain(
        identity: identity('guard'),
        entities: entities,
      );
      brain.memory.observe(
        target: GameEntityHandle('known', 1),
        position: Vec3.zero,
        tick: 1,
      );
      brain.decide(context(1, [GameGoal(id: 'idle', skill: 'idle')]));
      brain.reset(
        BrainReset(
          identity('guard', model: 'script-v2'),
          BrainResetReason.modelChanged,
        ),
      );
      expect(brain.memory.atTick(2), isEmpty);
      expect(() => brain.decide(context(2, [])), throwsArgumentError);
      await brain.close();
    },
  );
}

final class BurstSkill implements GameSkill {
  @override
  String get id => 'burst';
  @override
  GameRuleGraph get graph => GameRuleGraph(
    root: 'burst',
    nodes: [GameRuleNode.action('burst', 'burst')],
  );
  @override
  void register(GameActionRegistry actions, GamePredicateRegistry predicates) {
    actions.register(
      'burst',
      services: {'game.ai.context'},
      factory: (_) => BurstAction(),
    );
  }
}

final class BurstAction extends GameRuleAction {
  @override
  BehaviorStatus tick(BehaviorContext execution) {
    final permitted = execution
        .service<BrainSkillService>('game.ai.context')
        .context;
    expect(permitted.identity.entity, execution.actor);
    execution.enqueue('one', const {});
    execution.enqueue('two', const {});
    return BehaviorStatus.running;
  }
}
