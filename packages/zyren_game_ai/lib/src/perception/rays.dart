part of '../../zyren_game_ai.dart';

final class RaySensor extends _MeasuredSensor {
  final SensorProfile profile;
  final List<Vec3> directions;
  @override
  final String id;
  RaySensor(this.profile, {required List<Vec3> directions, this.id = 'rays'})
    : directions = List.unmodifiable(directions.map((v) => v.normalized())) {
    _bounded(directions.length, 256, 'directions');
  }
  @override
  int get cadenceTicks => profile.cadenceTicks;
  @override
  int get queryBudget => profile.queryBudget;
  @override
  late final ObservationSpec schema = ObservationSpec(
    id: id,
    configurationHash: _hash({
      'profile': profile.hash,
      'directions': directions.map((v) => v.storage).toList(),
    }),
    range: profile.range,
    cadenceTicks: cadenceTicks,
    maxRays: directions.length,
    fields: [
      ObservationField(
        'distance',
        units: 'metres',
        width: directions.length,
        min: 0,
        max: profile.range,
        scale: profile.range,
      ),
    ],
  );
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) {
    final actor = snapshot.entities[entity];
    if (actor == null) {
      return _empty(
        this,
        snapshot.tick,
        SensorState.unknown,
        'entity-missing',
        provenance: SensorProvenance.geometry,
      );
    }
    final budget = _QueryBudget(queryBudget);
    final hits = _rays(snapshot, actor, [
      for (final direction in directions)
        _SensorRay(
          actor.pose.position +
              actor.pose.rotation.rotate(direction) * profile.range,
          budget,
        ),
    ], profile);
    final state = hits.any((h) => h.state == SensorState.unavailable)
        ? SensorState.unavailable
        : hits.any((h) => h.state == SensorState.unknown)
        ? SensorState.unknown
        : SensorState.known;
    lastDiagnostics = SensorDiagnostics(
      id,
      snapshot.tick,
      state,
      queriesUsed: budget.used,
    );
    return SensorReading(
      sensorId: id,
      tick: snapshot.tick,
      state: state,
      provenance: SensorProvenance.geometry,
      values: hits
          .map(
            (h) => h.state == SensorState.known
                ? h.distance.clamp(0.0, profile.range)
                : 0.0,
          )
          .toList(),
      validity: hits.map((h) => h.state == SensorState.known ? 1 : 0).toList(),
    );
  }
}
