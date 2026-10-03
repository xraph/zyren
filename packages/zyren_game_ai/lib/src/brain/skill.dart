part of '../../zyren_game_ai.dart';

abstract interface class GameSkill {
  String get id;
  GameRuleGraph get graph;
  void register(GameActionRegistry actions, GamePredicateRegistry predicates);
}

final class GameSkillRegistry {
  final Map<String, GameRuleProgram> _programs = {};
  GameSkillRegistry();
  factory GameSkillRegistry.defaults() => GameSkillRegistry()
    ..register(_BuiltinSkill('investigate'))
    ..register(_BuiltinSkill('follow-route'))
    ..register(_BuiltinSkill('interact'))
    ..register(_BuiltinSkill('idle'));
  void register(GameSkill skill) {
    _name(skill.id);
    if (_programs.length >= 32 || _programs.containsKey(skill.id)) {
      throw StateError('Duplicate or excess skill.');
    }
    final actions = GameActionRegistry(), predicates = GamePredicateRegistry();
    skill.register(actions, predicates);
    final program = skill.graph.compile(actions, predicates);
    _programs[skill.id] = program;
  }

  GameRuleProgram program(String id) =>
      _programs[id] ?? (throw StateError('Unknown skill: $id.'));
  List<String> get ids => List.unmodifiable(_programs.keys);
}

enum SkillCancelReason { goalChanged, invalidTarget, reset, closed }

final class SkillCancellation {
  final String skillId, goalId;
  final BrainIdentity identity;
  final int tick;
  final SkillCancelReason reason;
  const SkillCancellation(
    this.skillId,
    this.goalId,
    this.identity,
    this.tick,
    this.reason,
  );
}

final class BrainSkillService {
  BrainContext? _context;
  BrainContext get context =>
      _context ?? (throw StateError('Skill context unavailable.'));
  final bool driver;
  BrainSkillService(this.driver);
}

final class _BuiltinSkill implements GameSkill {
  @override
  final String id;
  _BuiltinSkill(this.id);
  @override
  GameRuleGraph get graph => GameRuleGraph(
    root: 'skill',
    nodes: [GameRuleNode.action('skill', 'ai.$id')],
  );
  @override
  void register(GameActionRegistry actions, GamePredicateRegistry predicates) {
    actions.register(
      'ai.$id',
      services: {'game.ai.context'},
      factory: (_) => _BuiltinSkillAction(id),
    );
  }
}

final class _BuiltinSkillAction extends GameRuleAction {
  final String id;
  _BuiltinSkillAction(this.id);
  @override
  BehaviorStatus tick(BehaviorContext execution) {
    final service = execution.service<BrainSkillService>('game.ai.context');
    final context = service.context;
    final goal = context.goals.single;
    Vec3 direction = Vec3.zero;
    if (id == 'investigate') {
      final belief = context.beliefs
          .where((b) => b.key == goal.beliefKey)
          .firstOrNull;
      if (belief == null ||
          belief.confidence == 0 ||
          belief.positionFrame != context.identity.entity) {
        return BehaviorStatus.failed;
      }
      if (belief.position != null) {
        final planar = Vec3(belief.position!.x, 0, belief.position!.z);
        if (planar.length > .1) direction = planar.normalized();
      } else if (belief.sound != null) {
        final angle = belief.sound!.bearingRadians;
        direction = Vec3(math.sin(angle), 0, -math.cos(angle));
      }
    } else if (id == 'follow-route') {
      final index = context.utilityInputs['routeIndex'] ?? 0;
      if (index < 0 ||
          index != index.floorToDouble() ||
          index >= goal.route.length) {
        return BehaviorStatus.succeeded;
      }
      final point = goal.route[index.toInt()];
      final planar = Vec3(point.x, 0, point.z);
      if (planar.length > .1) direction = planar.normalized();
    } else if (id == 'interact') {
      if (goal.target == null ||
          !context.validTargets.contains(goal.target) ||
          context.utilityInputs['canInteract'] != 1) {
        return BehaviorStatus.failed;
      }
      execution.enqueue('ai.interact', {
        'targetId': goal.target!.id,
        'targetGeneration': goal.target!.generation,
      });
      return BehaviorStatus.succeeded;
    }
    if (service.driver) {
      final values = [
        direction.length == 0 ? 0.0 : .5,
        direction.length == 0 ? 1.0 : 0.0,
        direction.x,
      ];
      if (!context.actionSpec.accepts(values, const [])) {
        return BehaviorStatus.failed;
      }
      execution.enqueue('ai.drive', {
        'throttle': values[0],
        'brake': values[1],
        'steering': values[2],
      });
    } else {
      final values = [direction.x, direction.z];
      if (!context.actionSpec.accepts(values, const [])) {
        return BehaviorStatus.failed;
      }
      execution.enqueue('ai.move', {'moveX': values[0], 'moveZ': values[1]});
    }
    return BehaviorStatus.running;
  }
}
