part of '../../zyren_game_ai.dart';

enum SensorState { known, unknown, unavailable }

enum SensorProvenance {
  visible,
  audible,
  lastSeen,
  body,
  geometry,
  affordance,
  custom,
}

final class ObservedEntity {
  final GameEntityHandle handle;
  final Vec3 localPosition;
  final int tick;
  final SensorProvenance provenance;
  const ObservedEntity(
    this.handle,
    this.localPosition,
    this.tick,
    this.provenance,
  );
}

final class HeardSound {
  final String category;
  final int observedTick, eventTick;
  final double bearingRadians,
      bearingUncertaintyRadians,
      distanceLowerMetres,
      distanceUpperMetres;
  final bool obstructed;
  const HeardSound({
    required this.category,
    required this.observedTick,
    required this.eventTick,
    required this.bearingRadians,
    required this.bearingUncertaintyRadians,
    required this.distanceLowerMetres,
    required this.distanceUpperMetres,
    required this.obstructed,
  });
}

final class SensorReading {
  final String sensorId;
  final int tick;
  final SensorState state;
  final SensorProvenance provenance;
  final List<double> values;
  final List<int> validity;
  final List<ObservedEntity> entities;
  final List<HeardSound> sounds;
  final String? reason;
  SensorReading({
    required this.sensorId,
    required this.tick,
    required this.state,
    required this.provenance,
    required List<double> values,
    required List<int> validity,
    List<ObservedEntity> entities = const [],
    List<HeardSound> sounds = const [],
    this.reason,
  }) : values = List.unmodifiable(values),
       validity = List.unmodifiable(validity),
       entities = List.unmodifiable(entities),
       sounds = List.unmodifiable(sounds) {
    _name(sensorId);
    if (tick < 0 ||
        values.length != validity.length ||
        values.length > 16384 ||
        values.any((v) => !v.isFinite) ||
        validity.any((v) => v != 0 && v != 1)) {
      throw ArgumentError('Invalid sensor reading.');
    }
  }
}

final class ObservationFrame {
  final String episodeId, schemaHash, sensorProfileHash;
  final GameEntityHandle entity;
  final int tick, worldRevision;
  final List<SensorReading> readings;
  final List<ObservedEntity?> entities;
  final List<int> entityMask;
  final MlTensor tensor;
  ObservationFrame._({
    required this.episodeId,
    required this.schemaHash,
    required this.sensorProfileHash,
    required this.entity,
    required this.tick,
    required this.worldRevision,
    required List<SensorReading> readings,
    required List<ObservedEntity?> entities,
    required List<int> entityMask,
    required this.tensor,
  }) : readings = List.unmodifiable(readings),
       entities = List.unmodifiable(entities),
       entityMask = List.unmodifiable(entityMask);
  List<String> get visibleIds => List.unmodifiable(
    entities
        .whereType<ObservedEntity>()
        .where((e) => e.provenance == SensorProvenance.visible)
        .map((e) => e.handle.id),
  );
}
