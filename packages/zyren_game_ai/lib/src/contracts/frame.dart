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
  final String? reason, configurationHash;
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
    this.configurationHash,
  }) : values = List.unmodifiable(values),
       validity = List.unmodifiable(validity),
       entities = List.unmodifiable(entities),
       sounds = List.unmodifiable(sounds) {
    _name(sensorId);
    if (tick < 0 ||
        values.length != validity.length ||
        values.length > 131072 ||
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

  /// Builds raw, flat camera/body input from completed or explicitly unknown readings.
  /// This constructor does not resolve geometry or normalize unknown inputs.
  factory ObservationFrame.capturedReadings({
    required ObservationSpec spec,
    required String configurationHash,
    required String episodeId,
    required GameEntityHandle entity,
    required int tick,
    required int worldRevision,
    required List<SensorReading> readings,
  }) {
    _name(episodeId);
    if (tick < 0 ||
        worldRevision < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(configurationHash) ||
        spec.configurationHash != configurationHash ||
        spec.fields.length != 2 ||
        readings.length != 2 ||
        spec.fields[0].name != 'camera' ||
        spec.fields[1].name != 'own-body') {
      throw ArgumentError('Captured frame identity or schema differs.');
    }
    final copied = <SensorReading>[];
    for (var i = 0; i < 2; i++) {
      final reading = readings[i], field = spec.fields[i];
      if (reading.sensorId != field.name ||
          reading.tick != tick ||
          reading.configurationHash != configurationHash ||
          reading.provenance !=
              (i == 0 ? SensorProvenance.visible : SensorProvenance.body) ||
          reading.entities.isNotEmpty ||
          reading.sounds.isNotEmpty ||
          reading.values.length != field.width ||
          reading.values.any((v) => !field.accepts(v)) ||
          field.offset != 0 ||
          field.scale != 1 ||
          (reading.state != SensorState.known &&
              reading.validity.any((v) => v != 0))) {
        throw ArgumentError(
          'Captured reading provenance, bounds or availability differs.',
        );
      }
      // Store the same float32 values in readings and tensor, without aliasing input.
      final values = MlTensor.float32([
        1,
        field.width,
      ], reading.values).float32Values;
      copied.add(
        SensorReading(
          sensorId: reading.sensorId,
          tick: tick,
          state: reading.state,
          provenance: reading.provenance,
          configurationHash: configurationHash,
          values: values,
          validity: reading.validity,
          reason: reading.reason,
        ),
      );
    }
    return ObservationFrame._(
      episodeId: episodeId,
      schemaHash: spec.hash,
      sensorProfileHash: configurationHash,
      entity: entity,
      tick: tick,
      worldRevision: worldRevision,
      readings: copied,
      entities: [null],
      entityMask: [0],
      tensor: MlTensor.float32(
        [1, spec.width],
        [for (final reading in copied) ...reading.values],
      ),
    );
  }
  List<String> get visibleIds => List.unmodifiable(
    entities
        .whereType<ObservedEntity>()
        .where((e) => e.provenance == SensorProvenance.visible)
        .map((e) => e.handle.id),
  );
}
