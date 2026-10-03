part of '../../zyren_game_ai.dart';

final class GameGoal {
  final String id, skill;
  final int priority;
  final double utility;
  final GameEntityHandle? target;
  final String? beliefKey;
  final List<Vec3> route;
  GameGoal({
    required this.id,
    required this.skill,
    this.priority = 0,
    this.utility = 0,
    this.target,
    this.beliefKey,
    List<Vec3> route = const [],
  }) : route = List.unmodifiable(_sensorBoundedCopy(route, 256)) {
    _name(id);
    _name(skill);
    if (priority.abs() > 1000000 ||
        !utility.isFinite ||
        utility.abs() > 1000000 ||
        route.any(
          (p) => !p.isFinite || !p.length.isFinite || p.length > 100000,
        ) ||
        (beliefKey?.length ?? 0) > 2048) {
      throw ArgumentError('Invalid goal.');
    }
  }
}

abstract interface class GoalSelector {
  GameGoal? choose(BrainContext context);
  void reset();
}
