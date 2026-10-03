part of '../../zyren_game_ai.dart';

final class ObservationAssembler {
  final SensorRegistry registry;
  final SensorProfile profile;
  final List<GameSensor> _sensors;
  final ObservationSpec spec;
  factory ObservationAssembler({
    required SensorRegistry registry,
    required SensorProfile profile,
    String id = 'observation',
    int version = 1,
    int latencyTicks = 1,
  }) {
    final sensors = registry.sensors;
    if (sensors.isEmpty) throw ArgumentError('Register at least one sensor.');
    final fields = <ObservationField>[];
    for (final sensor in sensors) {
      for (final field in sensor.schema.fields) {
        fields.add(
          ObservationField(
            '${sensor.id}.${field.name}',
            units: field.units,
            width: field.width,
            min: field.min,
            max: field.max,
            offset: field.offset,
            scale: field.scale,
          ),
        );
      }
    }
    fields.add(
      ObservationField(
        'validity',
        width: fields.fold<int>(0, (n, f) => n + f.width),
        min: 0,
        max: 1,
      ),
    );
    return ObservationAssembler._(
      registry,
      profile,
      sensors,
      ObservationSpec(
        id: id,
        configurationHash: _hash({
          'profile': profile.hash,
          'sensors': sensors.map((s) => s.schema.hash).toList(),
        }),
        version: version,
        fields: fields,
        maxEntities: profile.maxEntities,
        range: profile.range,
        cadenceTicks: profile.cadenceTicks,
        latencyTicks: latencyTicks,
      ),
    );
  }
  ObservationAssembler._(this.registry, this.profile, this._sensors, this.spec);
  ObservationFrame build(SensorSnapshot snapshot, GameEntityHandle entity) {
    var readings = [
      for (final sensor in _sensors) registry.sample(sensor, snapshot, entity),
    ];
    if (!snapshot.isCurrent) {
      readings = [
        for (final sensor in _sensors)
          _empty(
            sensor,
            snapshot.tick,
            SensorState.unknown,
            'snapshot-revision',
          ),
      ];
    }
    final values = <double>[], masks = <double>[];
    for (var s = 0; s < readings.length; s++) {
      final reading = readings[s];
      var index = 0;
      for (final field in _sensors[s].schema.fields) {
        for (var i = 0; i < field.width; i++, index++) {
          final valid = reading.validity[index] == 1;
          values.add(
            valid ? (reading.values[index] - field.offset) / field.scale : 0,
          );
          masks.add(valid ? 1 : 0);
        }
      }
    }
    final seenHandles = <GameEntityHandle>{};
    final entities = readings
        .expand((r) => r.entities)
        .where(
          (e) =>
              e.provenance == SensorProvenance.visible &&
              seenHandles.add(e.handle),
        )
        .take(profile.maxEntities)
        .toList();
    final slots = <ObservedEntity?>[...entities];
    while (slots.length < profile.maxEntities) {
      slots.add(null);
    }
    return ObservationFrame._(
      episodeId: snapshot.episodeId,
      schemaHash: spec.hash,
      sensorProfileHash: _hash({
        'profile': profile.hash,
        'sensors': _sensors.map((s) => s.schema.hash).toList(),
      }),
      entity: entity,
      tick: snapshot.tick,
      worldRevision: snapshot.worldRevision,
      readings: readings,
      entities: slots,
      entityMask: slots.map((e) => e == null ? 0 : 1).toList(),
      tensor: MlTensor.float32([1, values.length * 2], [...values, ...masks]),
    );
  }
}

/// Capture and publish exactly once in the game sensors phase.
final class GamePerceptionSystem extends GameSystem {
  final GameSimulation Function() simulation;
  final ObservationAssembler assembler;
  final Iterable<GameEntityHandle> Function() actors;
  final SensorSnapshot Function(GameSimulation) capture;
  final void Function(ObservationFrame) publish;
  GamePerceptionSystem({
    required this.simulation,
    required this.assembler,
    required this.actors,
    required this.capture,
    required this.publish,
  });
  @override
  String get id => 'game.ai.perception';
  @override
  GamePhase get phase => GamePhase.sensors;
  @override
  void fixedUpdate(GameSession session) {
    if (!identical(simulation().session, session)) {
      throw StateError('Perception session mismatch.');
    }
    final snapshot = capture(simulation());
    if (snapshot.tick != session.tick) {
      throw StateError('Snapshot must identify the post-physics tick.');
    }
    final handles = _sensorBoundedCopy(actors(), 4096);
    if (handles.length > 4096) {
      throw StateError('Perception actor limit exceeded.');
    }
    for (final actor in handles) {
      if (session.entities.isAlive(actor)) {
        publish(assembler.build(snapshot, actor));
      }
    }
  }
}
