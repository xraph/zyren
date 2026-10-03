part of '../../zyren_game_ai.dart';

final class BrainIdentity {
  final String episodeId, modelHash;
  final GameEntityHandle entity;
  BrainIdentity({
    required this.episodeId,
    required this.entity,
    required this.modelHash,
  }) {
    _name(episodeId);
    _name(modelHash);
  }
  @override
  bool operator ==(Object other) =>
      other is BrainIdentity &&
      episodeId == other.episodeId &&
      entity == other.entity &&
      modelHash == other.modelHash;
  @override
  int get hashCode => Object.hash(episodeId, entity, modelHash);
}

enum BrainResetReason { episodeChanged, modelChanged, despawned, manual }

final class BrainReset {
  final BrainIdentity identity;
  final BrainResetReason reason;
  const BrainReset(this.identity, this.reason);
}

/// Permitted data only. No snapshot, scene, body or query-world reference.
final class BrainContext {
  final BrainIdentity identity;
  final int tick;
  final ObservationFrame? observation;
  final List<AgedBelief> beliefs;
  final List<GameGoal> goals;
  final Set<GameEntityHandle> validTargets;
  final ActionSpec actionSpec;
  final Map<String, double> utilityInputs;
  BrainContext({
    required this.identity,
    required this.tick,
    this.observation,
    required List<AgedBelief> beliefs,
    required List<GameGoal> goals,
    Set<GameEntityHandle> validTargets = const {},
    required this.actionSpec,
    Map<String, double> utilityInputs = const {},
  }) : beliefs = List.unmodifiable(_sensorBoundedCopy(beliefs, 1024)),
       goals = List.unmodifiable(_sensorBoundedCopy(goals, 128)),
       validTargets = Set.unmodifiable(_sensorBoundedCopy(validTargets, 1024)),
       utilityInputs = _brainUtilities(utilityInputs) {
    if (tick < 0 ||
        goals.map((g) => g.id).toSet().length != goals.length ||
        utilityInputs.length > 64 ||
        utilityInputs.values.any((v) => !v.isFinite || v.abs() > 1000000) ||
        beliefs.any((b) => b.observedTick > tick) ||
        (observation != null &&
            (observation!.entity != identity.entity ||
                observation!.episodeId != identity.episodeId ||
                observation!.tick > tick))) {
      throw ArgumentError('Invalid or foreign brain context.');
    }
  }
  bool permits(GameGoal goal) =>
      goal.target == null || validTargets.contains(goal.target);
}

final class BrainDecision {
  final BrainIdentity identity;
  final int observationTick, decisionTick;
  final GameGoal? goal;
  final BehaviorStatus status;
  final List<GameRuleCommand> actions;
  final String actionSchemaHash;
  BrainDecision._(
    this.identity,
    this.observationTick,
    this.decisionTick,
    this.goal,
    this.status,
    List<GameRuleCommand> actions,
    this.actionSchemaHash,
  ) : actions = List.unmodifiable(actions);

  /// The host validates both generations again before accepting commands.
  bool isApplicable(GameEntityTable entities, BrainIdentity currentIdentity) =>
      identity == currentIdentity &&
      entities.isAlive(identity.entity) &&
      (goal?.target == null || entities.isAlive(goal!.target!));
}

abstract interface class GameBrain {
  void observe(ObservationFrame frame);
  BrainDecision decide(BrainContext context);
  void reset(BrainReset reset);
  Future<void> close();
}

Map<String, double> _brainUtilities(Map<String, double> source) {
  if (source.length > 64) throw ArgumentError('Utility input limit exceeded.');
  for (final key in source.keys) {
    _name(key);
  }
  return Map.unmodifiable(source);
}
