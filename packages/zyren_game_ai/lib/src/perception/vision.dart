part of '../../zyren_game_ai.dart';

final class VisionSensor extends _MeasuredSensor {
  final SensorProfile profile;
  @override
  final String id;
  VisionSensor(this.profile, {this.id = 'vision'});
  @override
  int get cadenceTicks => profile.cadenceTicks;
  @override
  int get queryBudget => profile.queryBudget;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    configurationHash: profile.hash,
    range: profile.range,
    maxEntities: profile.maxEntities,
    cadenceTicks: cadenceTicks,
    fields: [
      ObservationField(
        'localPosition',
        units: 'metres',
        width: profile.maxEntities * 3,
        min: -profile.range,
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
        provenance: SensorProvenance.visible,
      );
    }
    final candidates =
        snapshot.entities.values
            .where(
              (e) =>
                  e.handle != entity &&
                  profile.contains(
                    _local(
                      actor.pose.rotation,
                      e.pose.position - actor.pose.position,
                    ),
                  ),
            )
            .toList()
          ..sort((a, b) => a.handle.id.compareTo(b.handle.id));
    final budget = _QueryBudget(queryBudget);
    final visible = <ObservedEntity>[];
    var state = SensorState.known;
    String? reason;
    if (candidates.length > profile.maxCandidates) {
      state = SensorState.unknown;
      reason = 'candidate-budget';
    }
    for (final candidate in candidates.take(profile.maxCandidates)) {
      if (visible.length >= profile.maxEntities) break;
      final hit = _ray(
        snapshot,
        actor,
        candidate.pose.position,
        profile,
        budget,
        target: candidate.handle,
      );
      if (hit.state != SensorState.known) {
        state = hit.state;
        reason = hit.reason;
        continue;
      }
      if (!hit.blocked) {
        visible.add(
          ObservedEntity(
            candidate.handle,
            _local(
              actor.pose.rotation,
              candidate.pose.position - actor.pose.position,
            ),
            snapshot.tick,
            SensorProvenance.visible,
          ),
        );
      }
    }
    lastDiagnostics = SensorDiagnostics(
      id,
      snapshot.tick,
      state,
      queriesUsed: budget.used,
      candidatesConsidered: math.min(candidates.length, profile.maxCandidates),
      reason: reason,
    );
    return SensorReading(
      sensorId: id,
      tick: snapshot.tick,
      state: state,
      provenance: SensorProvenance.visible,
      values: [
        for (var i = 0; i < profile.maxEntities; i++)
          ...i < visible.length
              ? visible[i].localPosition.storage
              : [0.0, 0.0, 0.0],
      ],
      validity: [
        for (var i = 0; i < profile.maxEntities; i++)
          ...List.filled(3, i < visible.length ? 1 : 0),
      ],
      entities: visible,
      reason: reason,
    );
  }
}

/// A bounded previous observation. It never follows a hidden target transform.
final class LastSeenSensor implements GameSensor {
  final SensorProfile profile;
  final int ttlTicks;
  ObservationFrame? _previous;
  LastSeenSensor(this.profile, {this.ttlTicks = 60}) {
    _bounded(ttlTicks, 36000, 'ttlTicks');
  }
  void remember(ObservationFrame frame) {
    _previous = frame;
  }

  @override
  String get id => 'lastSeen';
  @override
  int get cadenceTicks => profile.cadenceTicks;
  @override
  int get queryBudget => 0;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    configurationHash: _hash({'profile': profile.hash, 'ttlTicks': ttlTicks}),
    range: profile.range,
    maxEntities: profile.maxEntities,
    cadenceTicks: cadenceTicks,
    fields: [
      ObservationField(
        'positionAtCapture',
        units: 'metres',
        width: profile.maxEntities * 3,
        min: -profile.range,
        max: profile.range,
        scale: profile.range,
      ),
    ],
  );
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) {
    final frame = _previous;
    if (frame == null ||
        frame.episodeId != snapshot.episodeId ||
        frame.entity != entity ||
        frame.tick > snapshot.tick ||
        snapshot.tick - frame.tick > ttlTicks) {
      return _empty(
        this,
        snapshot.tick,
        SensorState.unknown,
        'memory-expired',
        provenance: SensorProvenance.lastSeen,
      );
    }
    final remembered = frame.entities
        .whereType<ObservedEntity>()
        .where(
          (e) =>
              e.provenance == SensorProvenance.visible &&
              e.localPosition.length <= profile.range,
        )
        .take(profile.maxEntities)
        .map(
          (e) => ObservedEntity(
            e.handle,
            e.localPosition,
            e.tick,
            SensorProvenance.lastSeen,
          ),
        )
        .toList();
    return SensorReading(
      sensorId: id,
      tick: snapshot.tick,
      state: SensorState.known,
      provenance: SensorProvenance.lastSeen,
      values: [
        for (var i = 0; i < profile.maxEntities; i++)
          ...i < remembered.length
              ? remembered[i].localPosition.storage
              : [0.0, 0.0, 0.0],
      ],
      validity: [
        for (var i = 0; i < profile.maxEntities; i++)
          ...List.filled(3, i < remembered.length ? 1 : 0),
      ],
      entities: remembered,
    );
  }
}
