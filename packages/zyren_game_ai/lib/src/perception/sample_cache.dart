part of '../../zyren_game_ai.dart';

/// Optional reuse of validated Body/Vision readings within one captured phase.
/// Custom sensors always run. Overflow samples freshly without retaining data.
final class SensorSampleCache {
  final int maxEntries, maxValues, maxGeometryChecks;
  final Map<(Object, GameEntityHandle), _CachedSensorReading> _readings = {};
  SensorSnapshot? _snapshot;
  int _values = 0, _geometryChecks = 0;
  int _hits = 0, _misses = 0, _capacityMisses = 0;
  SensorSampleCache({
    this.maxEntries = 512,
    this.maxValues = 131072,
    this.maxGeometryChecks = 4096,
  }) {
    _bounded(maxEntries, 4096, 'maxEntries');
    _bounded(maxValues, 1048576, 'maxValues');
    _bounded(maxGeometryChecks, 65536, 'maxGeometryChecks', zero: true);
  }
  int get entries => _readings.length;
  int get hits => _hits;
  int get misses => _misses;
  int get capacityMisses => _capacityMisses;
  void clear() {
    _readings.clear();
    _snapshot = null;
    _values = _geometryChecks = 0;
  }

  Object? _configuration(GameSensor sensor) => switch (sensor) {
    BodySensor() => (
      BodySensor,
      sensor.id,
      sensor.schema.hash,
      sensor.cadenceTicks,
      sensor.queryBudget,
      sensor.maxSpeed,
    ),
    VisionSensor() => (
      VisionSensor,
      sensor.id,
      sensor.schema.hash,
      sensor.cadenceTicks,
      sensor.queryBudget,
      sensor.profile.hash,
    ),
    _ => null,
  };

  SensorReading? _find(
    GameSensor sensor,
    SensorSnapshot snapshot,
    GameEntityHandle entity,
  ) {
    if (!identical(_snapshot, snapshot) || !snapshot.isCurrent) {
      clear();
      _snapshot = snapshot;
    }
    final configuration = _configuration(sensor);
    if (configuration == null || !snapshot.isCurrent) return null;
    final entry = _readings[(configuration, entity)];
    if (entry != null && entry.matches(snapshot)) {
      _hits++;
      return entry.reading;
    }
    _misses++;
    return null;
  }

  (_CachedSensorReading?, SensorReading) _sample(
    GameSensor sensor,
    SensorSnapshot snapshot,
    GameEntityHandle entity,
  ) {
    if (_configuration(sensor) == null) {
      return (null, sensor.sample(snapshot, entity));
    }
    final geometry = <(Vec3, Vec3, bool)>[];
    var overflow = false;
    final source = sensor is VisionSensor
        ? SensorSnapshot._(
            snapshot.episodeId,
            snapshot.tick,
            snapshot.worldRevision,
            snapshot.entities,
            snapshot.colliders,
            snapshot._world,
            snapshot._revision,
            (from, to) {
              final loaded = snapshot._geometryLoaded(from, to);
              if (_geometryChecks + geometry.length < maxGeometryChecks) {
                geometry.add((from, to, loaded));
              } else {
                overflow = true;
              }
              return loaded;
            },
            snapshot._sounds,
          )
        : snapshot;
    final reading = sensor.sample(source, entity);
    return (
      overflow
          ? null
          : _CachedSensorReading(
              reading,
              snapshot._world?.revision,
              snapshot._world?.isClosed,
              List.unmodifiable(geometry),
            ),
      reading,
    );
  }

  void _retain(
    GameSensor sensor,
    SensorSnapshot snapshot,
    GameEntityHandle entity,
    _CachedSensorReading? entry,
  ) {
    final configuration = _configuration(sensor);
    if (configuration == null || !snapshot.isCurrent) return;
    final key = (configuration, entity);
    final previous = _readings[key];
    final values = entry?.reading.values.length ?? 0;
    if (entry == null ||
        previous == null && _readings.length >= maxEntries ||
        _values - (previous?.reading.values.length ?? 0) + values > maxValues ||
        _geometryChecks -
                (previous?.geometry.length ?? 0) +
                entry.geometry.length >
            maxGeometryChecks) {
      _capacityMisses++;
      return;
    }
    _values += values - (previous?.reading.values.length ?? 0);
    _geometryChecks += entry.geometry.length - (previous?.geometry.length ?? 0);
    _readings[key] = entry;
  }
}

final class _CachedSensorReading {
  final SensorReading reading;
  final int? physicsRevision;
  final bool? closed;
  final List<(Vec3, Vec3, bool)> geometry;
  _CachedSensorReading(
    this.reading,
    this.physicsRevision,
    this.closed,
    this.geometry,
  );
  bool matches(SensorSnapshot snapshot) {
    bool current() =>
        snapshot.isCurrent &&
        snapshot._world?.revision == physicsRevision &&
        snapshot._world?.isClosed == closed;
    if (!current()) return false;
    for (final segment in geometry) {
      if (snapshot._geometryLoaded(segment.$1, segment.$2) != segment.$3) {
        return false;
      }
    }
    return current();
  }
}
