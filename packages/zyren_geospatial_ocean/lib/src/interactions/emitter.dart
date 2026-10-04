import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

/// Source-local monotonic identity. Retaining one watermark per source bounds
/// deduplication memory for simulations of any duration.
final class OceanInteractionId {
  final String source;
  final int sequence;
  OceanInteractionId(this.source, this.sequence) {
    if (source.trim().isEmpty ||
        source.length > 128 ||
        sequence < 0 ||
        sequence > 9007199254740991) {
      throw ArgumentError(
        'Interaction IDs need a bounded source and nonnegative sequence.',
      );
    }
  }
  @override
  bool operator ==(Object other) =>
      other is OceanInteractionId &&
      source == other.source &&
      sequence == other.sequence;
  @override
  int get hashCode => Object.hash(source, sequence);
}

/// Immutable visual disturbance in fixed ECEF coordinates and shared time.
/// [energy] is visual strength in square metres, not transferred mechanical
/// joules. Its square root sets a characteristic displacement before filtering.
final class OceanInteraction {
  final OceanInteractionId id;
  final GeoInstant time;
  final Vec3 ecefPosition, relativeVelocity;
  final double radiusMetres, energy;
  OceanInteraction({
    required this.id,
    required this.time,
    required this.ecefPosition,
    required this.relativeVelocity,
    required this.radiusMetres,
    required this.energy,
  }) {
    if (!ecefPosition.isFinite ||
        ecefPosition.length > 1e12 ||
        !relativeVelocity.isFinite ||
        relativeVelocity.length > 1000 ||
        !radiusMetres.isFinite ||
        radiusMetres < .01 ||
        radiusMetres > 1000 ||
        !energy.isFinite ||
        energy < 0 ||
        energy > 1e6) {
      throw ArgumentError('Invalid bounded ocean interaction.');
    }
  }
  OceanInteraction atGeneration(int generation) => OceanInteraction(
    id: id,
    time: GeoInstant(
      tick: time.tick,
      hz: time.hz,
      epoch: time.epoch,
      generation: generation,
      standard: time.standard,
    ),
    ecefPosition: ecefPosition,
    relativeVelocity: relativeVelocity,
    radiusMetres: radiusMetres,
    energy: energy,
  );
  Map<String, Object?> toJson() => {
    'version': 1,
    'source': id.source,
    'sequence': id.sequence,
    'tick': time.tick,
    'hz': time.hz,
    'epoch': time.epoch.toIso8601String(),
    'generation': time.generation,
    'standard': time.standard.name,
    'ecef': ecefPosition.storage,
    'velocity': relativeVelocity.storage,
    'radius': radiusMetres,
    'energy': energy,
  };
  factory OceanInteraction.fromJson(Map<String, Object?> json) {
    if (json['version'] != 1) {
      throw ArgumentError('Unsupported ocean interaction record.');
    }
    Vec3 vector(String key) {
      final input = json[key] as List;
      if (input.length != 3) {
        throw ArgumentError('Interaction vectors need three components.');
      }
      return Vec3.array(input.map((v) => (v as num).toDouble()).toList());
    }

    return OceanInteraction(
      id: OceanInteractionId(json['source'] as String, json['sequence'] as int),
      time: GeoInstant(
        tick: json['tick'] as int,
        hz: json['hz'] as int,
        epoch: DateTime.parse(json['epoch'] as String),
        generation: json['generation'] as int,
        standard: GeoTimeStandard.values.byName(json['standard'] as String),
      ),
      ecefPosition: vector('ecef'),
      relativeVelocity: vector('velocity'),
      radiusMetres: (json['radius'] as num).toDouble(),
      energy: (json['energy'] as num).toDouble(),
    );
  }
}

enum OceanInteractionAdmission {
  accepted,
  duplicate,
  late,
  wrongTimeline,
  outOfOrder,
  futureLimit,
  queueBudget,
  tickBudget,
  sourceBudget,
  outsideWindow,
  belowResolution,
}

/// Deterministic bounded delivery. A source must enqueue nondecreasing times and
/// strictly increasing sequences; sources may interleave in any order.
final class OceanInteractionQueue {
  final int maxPending, maxSources, maxPerTick, maxFutureTicks;
  GeoInstant _time;
  final _pending = <OceanInteraction>[];
  final _watermarks = <String, (int, int)>{};
  OceanInteractionQueue({
    required GeoInstant initialTime,
    this.maxPending = 256,
    this.maxSources = 128,
    this.maxPerTick = 64,
    this.maxFutureTicks = 600,
  }) : _time = initialTime {
    if (maxPending < 1 ||
        maxPending > 4096 ||
        maxSources < 1 ||
        maxSources > 1024 ||
        maxPerTick < 1 ||
        maxPerTick > maxPending ||
        maxFutureTicks < 1 ||
        maxFutureTicks > 1000000) {
      throw ArgumentError('Invalid bounded ocean event queue.');
    }
  }
  GeoInstant get time => _time;
  int get pendingCount => _pending.length;
  int get sourceCount => _watermarks.length;
  OceanInteractionAdmission enqueue(OceanInteraction event) {
    if (!event.time.sameTimeline(_time)) {
      return OceanInteractionAdmission.wrongTimeline;
    }
    if (event.time.tick <= _time.tick) return OceanInteractionAdmission.late;
    if (event.time.tick - _time.tick > maxFutureTicks) {
      return OceanInteractionAdmission.futureLimit;
    }
    final prior = _watermarks[event.id.source];
    if (prior != null && event.id.sequence <= prior.$1) {
      return OceanInteractionAdmission.duplicate;
    }
    if (prior != null && event.time.tick < prior.$2) {
      return OceanInteractionAdmission.outOfOrder;
    }
    if (prior == null && _watermarks.length >= maxSources) {
      return OceanInteractionAdmission.sourceBudget;
    }
    if (_pending.length >= maxPending) {
      return OceanInteractionAdmission.queueBudget;
    }
    if (_pending.where((e) => e.time.tick == event.time.tick).length >=
        maxPerTick) {
      return OceanInteractionAdmission.tickBudget;
    }
    _pending.add(event);
    _watermarks[event.id.source] = (event.id.sequence, event.time.tick);
    return OceanInteractionAdmission.accepted;
  }

  List<OceanInteraction> peekTick(GeoInstant instant) {
    if (!instant.sameTimeline(_time) || instant.tick != _time.tick + 1) {
      throw StateError(
        'Ocean interaction ticks must advance once on the current timeline.',
      );
    }
    final events = _pending.where((e) => e.time.tick == instant.tick).toList()
      ..sort((a, b) {
        final source = a.id.source.compareTo(b.id.source);
        return source != 0 ? source : a.id.sequence.compareTo(b.id.sequence);
      });
    return List.unmodifiable(events);
  }

  List<OceanInteraction> takeTick(GeoInstant instant) {
    final events = peekTick(instant);
    _pending.removeWhere((e) => e.time.tick == instant.tick);
    _time = instant;
    return events;
  }

  void reset(int generation, {int tick = 0}) {
    if (generation <= _time.generation) {
      throw ArgumentError('Replay requires a newer interaction generation.');
    }
    final time = GeoInstant(
      tick: tick,
      hz: _time.hz,
      epoch: _time.epoch,
      generation: generation,
      standard: _time.standard,
    );
    _pending.clear();
    _watermarks.clear();
    _time = time;
  }
}
