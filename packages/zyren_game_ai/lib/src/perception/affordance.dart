part of '../../zyren_game_ai.dart';

/// The controller supplies legality for the observing actor, not hidden peers.
final class AffordanceSensor implements GameSensor {
  final List<String> actions;
  @override
  final int cadenceTicks;
  AffordanceSensor({required List<String> actions, this.cadenceTicks = 1})
    : actions = List.unmodifiable(actions) {
    _bounded(actions.length, 64, 'actions');
    for (final action in actions) {
      _name(action);
    }
    if (actions.toSet().length != actions.length) {
      throw ArgumentError('Duplicate affordance.');
    }
  }
  @override
  String get id => 'affordance';
  @override
  int get queryBudget => 0;
  @override
  late final ObservationSpec schema = ObservationSpec(
    id: id,
    cadenceTicks: cadenceTicks,
    fields: [
      for (final action in actions) ObservationField(action, min: 0, max: 1),
    ],
  );
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) {
    final values = snapshot.entities[entity]?.affordances;
    if (values == null || values.length != actions.length) {
      return _empty(
        this,
        snapshot.tick,
        SensorState.unknown,
        'legality-unavailable',
        provenance: SensorProvenance.affordance,
      );
    }
    return SensorReading(
      sensorId: id,
      tick: snapshot.tick,
      state: SensorState.known,
      provenance: SensorProvenance.affordance,
      values: values,
      validity: List.filled(values.length, 1),
    );
  }
}
