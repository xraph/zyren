part of '../../zyren_game_ai.dart';

abstract interface class GameSensor {
  String get id;
  ObservationSpec get schema;
  int get cadenceTicks;
  int get queryBudget;
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity);
}

final class SensorDiagnostics {
  final String sensorId;
  final int tick, queriesUsed, candidatesConsidered;
  final SensorState state;
  final String? reason;
  const SensorDiagnostics(
    this.sensorId,
    this.tick,
    this.state, {
    this.queriesUsed = 0,
    this.candidatesConsidered = 0,
    this.reason,
  });
}

final class SensorRegistry {
  final Map<String, GameSensor> _sensors = {};
  final Map<String, (String, int, int)> _pins = {};
  (String, int, int) _pin(GameSensor s) =>
      (s.schema.hash, s.cadenceTicks, s.queryBudget);
  final Map<String, SensorDiagnostics> _diagnostics = {};
  List<GameSensor> get sensors => List.unmodifiable(_sensors.values);
  List<SensorDiagnostics> get diagnostics =>
      List.unmodifiable(_diagnostics.values);
  void register(GameSensor sensor) {
    _name(sensor.id);
    _bounded(sensor.cadenceTicks, 3600, 'cadenceTicks');
    _bounded(sensor.queryBudget, 4096, 'queryBudget', zero: true);
    if (_sensors.length >= 64 || _sensors.containsKey(sensor.id)) {
      throw StateError('Sensor registry full or duplicate.');
    }
    if (sensor.schema.cadenceTicks != sensor.cadenceTicks) {
      throw ArgumentError('Sensor/schema cadence mismatch.');
    }
    if (_sensors.values.fold<int>(0, (n, s) => n + s.queryBudget) +
            sensor.queryBudget >
        4096) {
      throw StateError('Aggregate sensor query budget exceeded.');
    }
    _sensors[sensor.id] = sensor;
    _pins[sensor.id] = _pin(sensor);
  }

  void unregister(String id) {
    _sensors.remove(id);
    _pins.remove(id);
    _diagnostics.remove(id);
  }

  SensorReading sample(
    GameSensor sensor,
    SensorSnapshot snapshot,
    GameEntityHandle entity,
  ) {
    if (!identical(_sensors[sensor.id], sensor) ||
        _pins[sensor.id] != _pin(sensor)) {
      throw StateError(
        'Sensor registration or schema changed. Rebuild the assembler.',
      );
    }
    SensorReading reading;
    if (snapshot.tick % sensor.cadenceTicks != 0 ||
        !snapshot.isCurrent ||
        !snapshot.entities.containsKey(entity)) {
      reading = _empty(
        sensor,
        snapshot.tick,
        SensorState.unknown,
        'cadence-or-stale-entity',
      );
    } else {
      reading = sensor.sample(snapshot, entity);
      if (_pins[sensor.id] != _pin(sensor)) {
        throw StateError('Sensor schema changed while sampling.');
      }
      if (reading.sensorId != sensor.id ||
          reading.tick != snapshot.tick ||
          reading.values.length != sensor.schema.width) {
        throw StateError('Custom sensor returned a mismatched schema/frame.');
      }
      var offset = 0;
      for (final field in sensor.schema.fields) {
        for (var i = 0; i < field.width; i++, offset++) {
          if (reading.validity[offset] == 1 &&
              !field.accepts(reading.values[offset])) {
            throw StateError('Sensor value exceeds schema bounds.');
          }
        }
      }
      if (!snapshot.isCurrent) {
        reading = _empty(
          sensor,
          snapshot.tick,
          SensorState.unknown,
          'snapshot-revision',
        );
      }
    }
    final measured = sensor is _MeasuredSensor ? sensor.lastDiagnostics : null;
    _diagnostics[sensor.id] = SensorDiagnostics(
      sensor.id,
      snapshot.tick,
      reading.state,
      queriesUsed: measured?.tick == snapshot.tick
          ? measured?.queriesUsed ?? 0
          : 0,
      candidatesConsidered: measured?.tick == snapshot.tick
          ? measured?.candidatesConsidered ?? 0
          : 0,
      reason: reading.reason,
    );
    return reading;
  }
}

abstract class _MeasuredSensor implements GameSensor {
  SensorDiagnostics? lastDiagnostics;
}

SensorReading _empty(
  GameSensor sensor,
  int tick,
  SensorState state,
  String reason, {
  SensorProvenance? provenance,
}) => SensorReading(
  sensorId: sensor.id,
  tick: tick,
  state: state,
  provenance: provenance ?? _provenance(sensor),
  values: List.filled(sensor.schema.width, 0),
  validity: List.filled(sensor.schema.width, 0),
  reason: reason,
);

SensorProvenance _provenance(GameSensor sensor) => switch (sensor) {
  VisionSensor() => SensorProvenance.visible,
  LastSeenSensor() => SensorProvenance.lastSeen,
  HearingSensor() => SensorProvenance.audible,
  BodySensor() => SensorProvenance.body,
  AffordanceSensor() => SensorProvenance.affordance,
  RaySensor() || GridSensor() => SensorProvenance.geometry,
  _ => SensorProvenance.custom,
};
