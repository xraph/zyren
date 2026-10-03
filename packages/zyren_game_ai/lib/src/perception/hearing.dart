part of '../../zyren_game_ai.dart';

/// Service-only sound input adapted from the gameplay event journal.
final class SensorSoundSample {
  final String id, category;
  final int tick;
  final Vec3 position;
  final double loudness, range;
  factory SensorSoundSample.fromEvent(GameSoundEvent event) =>
      SensorSoundSample(
        id: event.id,
        category: event.category,
        tick: event.tick,
        position: event.position,
        loudness: event.loudness,
        range: event.range,
      );
  SensorSoundSample({
    required this.id,
    required this.category,
    required this.tick,
    required this.position,
    required this.loudness,
    required this.range,
  }) {
    if (id.trim().isEmpty || id.length > 1024) {
      throw ArgumentError('Invalid sound id.');
    }
    _name(category);
    if (tick < 0 ||
        !position.isFinite ||
        !loudness.isFinite ||
        loudness < 0 ||
        loudness > 1 ||
        !range.isFinite ||
        range <= 0) {
      throw ArgumentError('Invalid semantic sound.');
    }
  }
}

final class HearingSensor extends _MeasuredSensor {
  final SensorProfile profile;
  final int maxSounds, bearingSectors, distanceBands, ttlTicks;
  final double minLoudness, obstructionGain;
  final List<String> categories;
  HearingSensor(
    this.profile, {
    this.maxSounds = 8,
    this.bearingSectors = 8,
    this.distanceBands = 4,
    this.ttlTicks = 30,
    this.minLoudness = .05,
    this.obstructionGain = .25,
    List<String> categories = const ['footstep', 'impact', 'voice'],
  }) : categories = List.unmodifiable(categories) {
    _bounded(maxSounds, 64, 'maxSounds');
    _bounded(bearingSectors, 64, 'bearingSectors');
    _bounded(distanceBands, 32, 'distanceBands');
    _bounded(ttlTicks, 36000, 'ttlTicks');
    _bounded(categories.length, 64, 'categories');
    for (final c in categories) {
      _name(c);
    }
    if (categories.toSet().length != categories.length ||
        !minLoudness.isFinite ||
        minLoudness < 0 ||
        minLoudness > 1 ||
        !obstructionGain.isFinite ||
        obstructionGain < 0 ||
        obstructionGain > 1) {
      throw ArgumentError('Invalid hearing policy.');
    }
  }
  @override
  String get id => 'hearing';
  @override
  int get cadenceTicks => profile.cadenceTicks;
  @override
  int get queryBudget => profile.queryBudget;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    configurationHash: _hash({
      'profile': profile.hash,
      'allocation': 'stable-catalog-v1',
      'maxSounds': maxSounds,
      'bearingSectors': bearingSectors,
      'distanceBands': distanceBands,
      'ttlTicks': ttlTicks,
      'minLoudness': minLoudness,
      'obstructionGain': obstructionGain,
      'categories': categories,
    }),
    range: profile.range,
    cadenceTicks: cadenceTicks,
    fields: [
      ObservationField(
        'sound',
        width: maxSounds * 5,
        min: 0,
        max: math
            .max(
              math.max(bearingSectors, distanceBands),
              math.max(categories.length, ttlTicks),
            )
            .toDouble(),
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
        provenance: SensorProvenance.audible,
      );
    }
    final candidates =
        snapshot._sounds
            .where(
              (sound) =>
                  categories.contains(sound.category) &&
                  sound.tick <= snapshot.tick &&
                  snapshot.tick - sound.tick <= ttlTicks,
            )
            .toList()
          ..sort((a, b) {
            final t = b.tick.compareTo(a.tick);
            return t == 0 ? a.id.compareTo(b.id) : t;
          });
    final values = <double>[];
    final admitted = candidates.take(profile.maxCandidates).toList();
    var queriesUsed = 0;
    final heard = <HeardSound>[];
    var state = SensorState.known;
    String? reason;
    for (var slot = 0; slot < admitted.length; slot++) {
      final sound = admitted[slot];
      final budget = _QueryBudget(
        _catalogQuota(queryBudget, admitted.length, slot),
      );
      if (values.length >= maxSounds * 5) break;
      final distance = sound.position.distanceTo(actor.pose.position);
      if (distance > math.min(sound.range, profile.range)) continue;
      final unobstructed = sound.loudness * (1 - distance / sound.range);
      if (unobstructed <= 0 || unobstructed < minLoudness) continue;
      final hit = _ray(snapshot, actor, sound.position, profile, budget);
      queriesUsed += budget.used;
      if (hit.state != SensorState.known) {
        state = hit.state;
        reason = hit.reason;
        continue;
      }
      final audible = unobstructed * (hit.blocked ? obstructionGain : 1);
      if (audible < minLoudness) continue;
      final local = _local(
        actor.pose.rotation,
        sound.position - actor.pose.position,
      );
      final angle =
          (math.atan2(local.x, -local.z) + 2 * math.pi) % (2 * math.pi);
      final sector = (angle / (2 * math.pi) * bearingSectors).floor();
      final band = math.min(
        distanceBands - 1,
        (distance / profile.range * distanceBands).floor(),
      );
      // Only authored quantized bins, category and event age enter the policy.
      // Continuous amplitude would otherwise leak exact source distance.
      heard.add(
        HeardSound(
          category: sound.category,
          observedTick: snapshot.tick,
          eventTick: sound.tick,
          bearingRadians: (sector + .5) * 2 * math.pi / bearingSectors,
          bearingUncertaintyRadians: bearingUncertaintyRadians,
          distanceLowerMetres: band * profile.range / distanceBands,
          distanceUpperMetres: (band + 1) * profile.range / distanceBands,
          obstructed: hit.blocked,
        ),
      );
      values.addAll([
        sector.toDouble(),
        band.toDouble(),
        categories.indexOf(sound.category).toDouble(),
        (snapshot.tick - sound.tick).toDouble(),
        hit.blocked ? 1 : 0,
      ]);
    }
    final known = values.length;
    while (values.length < maxSounds * 5) {
      values.add(0);
    }
    final coverageState = state == SensorState.unavailable
        ? state
        : heard.length < candidates.length
        ? SensorState.unknown
        : state;
    lastDiagnostics = SensorDiagnostics(
      id,
      snapshot.tick,
      state,
      queriesUsed: queriesUsed,
      candidatesConsidered: math.min(candidates.length, profile.maxCandidates),
      reason: reason,
    );
    return SensorReading(
      sensorId: id,
      tick: snapshot.tick,
      state: coverageState,
      provenance: SensorProvenance.audible,
      sounds: heard,
      values: values,
      validity: [for (var i = 0; i < values.length; i++) i < known ? 1 : 0],
      reason: coverageState == SensorState.unknown
          ? 'partial-catalog-coverage'
          : reason,
    );
  }

  double get bearingUncertaintyRadians => math.pi / bearingSectors;
  double get distanceUncertaintyMetres => profile.range / distanceBands;
}
