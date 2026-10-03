part of '../../zyren_game_ai.dart';

/// Authored scoring receives only the permitted context.
final class UtilityGoalSelector implements GoalSelector {
  final int minCommitmentTicks;
  final double Function(GameGoal, BrainContext)? score;
  GameGoal? _current;
  int _chosenTick = -1, _lastTick = -1;
  UtilityGoalSelector({this.minCommitmentTicks = 5, this.score}) {
    _bounded(minCommitmentTicks, 36000, 'minCommitmentTicks', zero: true);
  }
  @override
  GameGoal? choose(BrainContext context) {
    if (context.tick < _lastTick) {
      throw StateError('Goal ticks cannot move backwards.');
    }
    _lastTick = context.tick;
    final eligible = context.goals.where(context.permits).toList();
    final previous = _current;
    final retained = previous == null
        ? null
        : eligible
              .where(
                (g) =>
                    g.id == previous.id &&
                    g.target == previous.target &&
                    g.skill == previous.skill,
              )
              .firstOrNull;
    if (retained != null && context.tick - _chosenTick < minCommitmentTicks) {
      return _current = retained;
    }
    final scores = <String, double>{};
    for (final goal in eligible) {
      final value = score?.call(goal, context) ?? goal.utility;
      if (!value.isFinite || value.abs() > 1000000) {
        throw ArgumentError('Utility score exceeds bounds.');
      }
      scores[goal.id] = value;
    }
    eligible.sort((a, b) {
      final priority = b.priority.compareTo(a.priority);
      if (priority != 0) return priority;
      final utility = scores[b.id]!.compareTo(scores[a.id]!);
      return utility == 0 ? a.id.compareTo(b.id) : utility;
    });
    final next = eligible.firstOrNull;
    if (next?.id != _current?.id ||
        next?.target != _current?.target ||
        next?.skill != _current?.skill) {
      _chosenTick = context.tick;
    }
    return _current = next;
  }

  @override
  void reset() {
    _current = null;
    _chosenTick = -1;
    _lastTick = -1;
  }
}
