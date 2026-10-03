part of '../../zyren_game_ai.dart';

/// Occupancy of declared local cells through the existing native overlap query.
final class GridSensor extends _MeasuredSensor {
  final SensorProfile profile;
  final List<Vec3> centers;
  final double radius;
  @override
  final String id;
  GridSensor(
    this.profile, {
    required List<Vec3> centers,
    this.radius = .25,
    this.id = 'grid',
  }) : centers = List.unmodifiable(centers) {
    _bounded(centers.length, 256, 'centers');
    if (!radius.isFinite ||
        radius <= 0 ||
        centers.any((v) => !v.isFinite || v.length + radius > profile.range)) {
      throw ArgumentError('Grid cells exceed sensor range.');
    }
  }
  @override
  int get cadenceTicks => profile.cadenceTicks;
  @override
  int get queryBudget => profile.queryBudget;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    configurationHash: _hash({
      'profile': profile.hash,
      'centers': centers.map((v) => v.storage).toList(),
      'radius': radius,
    }),
    range: profile.range,
    cadenceTicks: cadenceTicks,
    fields: [
      ObservationField('occupied', width: centers.length, min: 0, max: 1),
    ],
  );
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) {
    final actor = snapshot.entities[entity], world = snapshot._world;
    if (actor == null || world == null || world.isClosed) {
      return _empty(
        this,
        snapshot.tick,
        SensorState.unavailable,
        'physics-unavailable',
        provenance: SensorProvenance.geometry,
      );
    }
    final budget = _QueryBudget(queryBudget),
        values = <double>[],
        mask = <int>[];
    for (final local in centers) {
      final center = actor.pose.position + actor.pose.rotation.rotate(local);
      var known =
          snapshot.isCurrent &&
          snapshot._geometryLoaded(
            center - Vec3.one * radius,
            center + Vec3.one * radius,
          );
      var occupied = false;
      if (known && budget.take()) {
        try {
          final hits = world.overlap(
            shape: SphereShape(radius),
            pose: PhysicsPose(position: center),
            filter: QueryFilter(
              excludeBody: actor.body,
              excludeSensors: true,
              filter: profile.layerMask,
            ),
          );
          for (final hit in hits) {
            final rule =
                profile.materials[snapshot.colliders[hit]?.material ??
                    SensorMaterial.unknown]!;
            if (rule == SensorMaterialRule.unknown) known = false;
            if (rule == SensorMaterialRule.block) occupied = true;
          }
          known = known && snapshot.isCurrent;
        } on PhysicsException {
          known = false;
        } on StateError {
          known = false;
        }
      } else {
        known = false;
      }
      values.add(known && occupied ? 1 : 0);
      mask.add(known ? 1 : 0);
    }
    final state = mask.contains(0) ? SensorState.unknown : SensorState.known;
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
      values: values,
      validity: mask,
    );
  }
}
