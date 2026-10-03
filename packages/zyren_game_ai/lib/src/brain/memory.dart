part of '../../zyren_game_ai.dart';

final class MemoryProfile {
  final int maxBeliefs, maxSerializedBytes, ttlTicks;
  final double confidenceDecayPerTick;
  MemoryProfile({
    this.maxBeliefs = 64,
    this.maxSerializedBytes = 65536,
    this.ttlTicks = 60,
    this.confidenceDecayPerTick = 0,
  }) {
    _bounded(maxBeliefs, 1024, 'maxBeliefs');
    _bounded(maxSerializedBytes, 1048576, 'maxSerializedBytes');
    _bounded(ttlTicks, 36000, 'ttlTicks');
    if (!confidenceDecayPerTick.isFinite ||
        confidenceDecayPerTick < 0 ||
        confidenceDecayPerTick > 1) {
      throw ArgumentError('Invalid confidence decay.');
    }
  }
  String get hash => _hash({
    'maxBeliefs': maxBeliefs,
    'maxBytes': maxSerializedBytes,
    'ttlTicks': ttlTicks,
    'decay': confidenceDecayPerTick,
  });
}

final class MemoryDiagnostics {
  final int retainedBeliefs, accountedBytes, evictions, rejectedObservations;
  const MemoryDiagnostics(
    this.retainedBeliefs,
    this.accountedBytes,
    this.evictions,
    this.rejectedObservations,
  );
}

final class _MemoryEntry {
  final Belief belief;
  final int bytes;
  int? unknownTick;
  _MemoryEntry(this.belief, this.bytes);
}

final class MemorySnapshot {
  final BrainIdentity identity;
  final String profileHash;
  final int savedTick;
  final List<Belief> _beliefs;
  final Map<String, int> _unknownTicks;
  MemorySnapshot._(
    this.identity,
    this.profileHash,
    this.savedTick,
    List<Belief> beliefs,
    Map<String, int> unknown,
  ) : _beliefs = List.unmodifiable(beliefs),
      _unknownTicks = Map.unmodifiable(unknown);
  String encode() => jsonEncode({
    'version': 1,
    'identity': _memoryIdentity(identity),
    'profileHash': profileHash,
    'savedTick': savedTick,
    'unknownTicks': _unknownTicks,
    'beliefs': _beliefs.map(_beliefJson).toList(),
  });
  factory MemorySnapshot.decode(String source) {
    if (source.length > 1048576 || utf8.encode(source).length > 1048576) {
      throw const FormatException('Memory snapshot byte limit exceeded.');
    }
    final json = jsonDecode(source) as Map<String, dynamic>;
    if (json['version'] != 1) {
      throw const FormatException('Unknown memory snapshot version.');
    }
    final who = json['identity'] as Map<String, dynamic>;
    final identity = BrainIdentity(
      episodeId: who['episodeId'] as String,
      entity: _readMemoryHandle(who['entity']),
      modelHash: who['modelHash'] as String,
    );
    final savedTick = json['savedTick'] as int,
        profileHash = json['profileHash'] as String;
    final raw = json['beliefs'] as List<dynamic>,
        unknown = json['unknownTicks'] as Map<String, dynamic>;
    if (savedTick < 0 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(profileHash) ||
        raw.length > 1024 ||
        unknown.length > raw.length) {
      throw const FormatException('Invalid memory snapshot envelope.');
    }
    final beliefs = <Belief>[];
    for (final item in raw) {
      final b = item as Map<String, dynamic>;
      final position = b['position'] as List<dynamic>?;
      if (position != null && position.length != 3) {
        throw const FormatException('Invalid belief position.');
      }
      final s = b['sound'] as Map<String, dynamic>?;
      final sound = s == null
          ? null
          : HeardSound(
              category: s['category'] as String,
              observedTick: s['observedTick'] as int,
              eventTick: s['eventTick'] as int,
              bearingRadians: (s['bearing'] as num).toDouble(),
              bearingUncertaintyRadians: (s['uncertainty'] as num).toDouble(),
              distanceLowerMetres: (s['lower'] as num).toDouble(),
              distanceUpperMetres: (s['upper'] as num).toDouble(),
              obstructed: s['obstructed'] as bool,
            );
      final belief = Belief._(
        key: b['key'] as String,
        target: b['target'] == null ? null : _readMemoryHandle(b['target']),
        position: position == null
            ? null
            : Vec3(
                (position[0] as num).toDouble(),
                (position[1] as num).toDouble(),
                (position[2] as num).toDouble(),
              ),
        positionFrame: _readMemoryHandle(b['positionFrame']),
        observedTick: b['observedTick'] as int,
        ttlTicks: b['ttlTicks'] as int,
        source: BeliefSource.values.byName(b['source'] as String),
        confidence: (b['confidence'] as num).toDouble(),
        sound: sound,
      );
      if (belief.observedTick > savedTick || belief.observedTick < 0) {
        throw const FormatException('Future belief in snapshot.');
      }
      if (sound != null &&
          (sound.eventTick < 0 ||
              sound.observedTick < sound.eventTick ||
              sound.eventTick > savedTick ||
              sound.observedTick > savedTick ||
              sound.category.length > 128 ||
              !sound.bearingRadians.isFinite ||
              !sound.bearingUncertaintyRadians.isFinite ||
              sound.bearingUncertaintyRadians <= 0 ||
              !sound.distanceLowerMetres.isFinite ||
              !sound.distanceUpperMetres.isFinite ||
              sound.distanceLowerMetres < 0 ||
              sound.distanceUpperMetres <= sound.distanceLowerMetres)) {
        throw const FormatException('Invalid sound belief.');
      }
      beliefs.add(belief);
    }
    if (beliefs.map((b) => b.key).toSet().length != beliefs.length) {
      throw const FormatException('Duplicate memory key.');
    }
    final unknownTicks = unknown.map(
      (key, value) => MapEntry(key, value as int),
    );
    for (final item in unknownTicks.entries) {
      if (!beliefs.any((b) => b.key == item.key) ||
          item.value < 0 ||
          item.value > savedTick) {
        throw const FormatException('Invalid unknown timestamp.');
      }
    }
    return MemorySnapshot._(
      identity,
      profileHash,
      savedTick,
      beliefs,
      unknownTicks,
    );
  }
}

/// Each actor owns this store. No scene, physics or native query API is retained.
final class BeliefStore {
  BrainIdentity _identity;
  BrainIdentity get identity => _identity;
  final MemoryProfile profile;
  final Map<String, _MemoryEntry> _entries = {};
  int _bytes = 0, _evictions = 0, _rejected = 0;
  BeliefStore({required BrainIdentity identity, MemoryProfile? profile})
    : _identity = identity,
      profile = profile ?? MemoryProfile() {
    _bytes = _envelopeBytes;
    if (_bytes > this.profile.maxSerializedBytes) {
      throw ArgumentError('Memory budget cannot hold its identity envelope.');
    }
  }
  int get _envelopeBytes =>
      utf8
          .encode(
            jsonEncode({
              'version': 1,
              'identity': _memoryIdentity(identity),
              'profileHash': profile.hash,
              'savedTick': 9223372036854775807,
              'unknownTicks': <String, int>{},
              'beliefs': <Object>[],
            }),
          )
          .length +
      64;
  MemoryDiagnostics get diagnostics =>
      MemoryDiagnostics(_entries.length, _bytes, _evictions, _rejected);
  String _targetKey(GameEntityHandle target) =>
      'entity:${target.id}@${target.generation}';
  bool observe({
    required GameEntityHandle target,
    required Vec3 position,
    required int tick,
    BeliefSource source = BeliefSource.visible,
    double confidence = 1,
    int? ttlTicks,
    GameEntityHandle? positionFrame,
  }) => _put(
    Belief._(
      key: _targetKey(target),
      target: target,
      position: position,
      positionFrame: positionFrame ?? identity.entity,
      observedTick: tick,
      ttlTicks: ttlTicks ?? profile.ttlTicks,
      source: source,
      confidence: confidence,
    ),
  );

  bool _put(Belief belief) {
    if (belief.observedTick < 0 ||
        belief.ttlTicks < 1 ||
        belief.ttlTicks > profile.ttlTicks ||
        !(belief.position?.isFinite ?? true) ||
        (belief.position != null &&
            (!belief.position!.length.isFinite ||
                belief.position!.length > 100000)) ||
        !belief.confidence.isFinite ||
        belief.confidence < 0 ||
        belief.confidence > 1 ||
        belief.key.length > 2048) {
      throw ArgumentError('Invalid belief.');
    }
    final previous = _entries[belief.key];
    if (previous != null &&
        previous.belief.observedTick >= belief.observedTick) {
      return false;
    }
    // Reserve the actual portable entry, its optional unknown key and tick
    // growth on restore. The envelope is accounted separately.
    final size =
        utf8.encode(jsonEncode(_beliefJson(belief))).length +
        utf8.encode(jsonEncode(belief.key)).length +
        128;
    if (_envelopeBytes + size > profile.maxSerializedBytes) {
      _rejected++;
      return false;
    }
    if (previous != null) {
      _entries.remove(belief.key);
      _bytes -= previous.bytes;
    }
    while (_entries.length >= profile.maxBeliefs ||
        _bytes + size > profile.maxSerializedBytes) {
      final ordered = _entries.values.toList()
        ..sort((a, b) {
          final expiredA =
              belief.observedTick - a.belief.observedTick > a.belief.ttlTicks;
          final expiredB =
              belief.observedTick - b.belief.observedTick > b.belief.ttlTicks;
          if (expiredA != expiredB) return expiredA ? -1 : 1;
          final tick = a.belief.observedTick.compareTo(b.belief.observedTick);
          return tick == 0 ? a.belief.key.compareTo(b.belief.key) : tick;
        });
      final evicted = ordered.first;
      _entries.remove(evicted.belief.key);
      _bytes -= evicted.bytes;
      _evictions++;
    }
    _entries[belief.key] = _MemoryEntry(belief, size);
    _bytes += size;
    return true;
  }

  void observeFrame(ObservationFrame frame) {
    if (frame.episodeId != identity.episodeId ||
        frame.entity != identity.entity) {
      throw ArgumentError('Foreign observation frame.');
    }
    for (final entity in _sensorBoundedCopy(
      frame.entities.whereType<ObservedEntity>(),
      256,
    )) {
      if (entity.tick > frame.tick) {
        throw ArgumentError('Future entity observation.');
      }
      if (entity.provenance == SensorProvenance.visible) {
        observe(
          target: entity.handle,
          position: entity.localPosition,
          tick: entity.tick,
        );
      }
    }
    final visionUnknown = frame.readings.any(
      (r) =>
          r.provenance == SensorProvenance.visible &&
          r.state != SensorState.known,
    );
    if (visionUnknown) {
      final visible = frame.entities
          .whereType<ObservedEntity>()
          .map((e) => e.handle)
          .toSet();
      for (final entry in _entries.values) {
        if (entry.belief.target != null &&
            !visible.contains(entry.belief.target)) {
          entry.unknownTick = frame.tick;
        }
      }
    }
    for (final reading in frame.readings) {
      for (final sound in _sensorBoundedCopy(reading.sounds, 64)) {
        if (sound.eventTick > frame.tick) {
          throw ArgumentError('Future sound observation.');
        }
        _put(
          Belief._(
            key:
                'sound:${sound.category}:${sound.eventTick}:${sound.bearingRadians}',
            target: null,
            position: null,
            positionFrame: identity.entity,
            observedTick: sound.eventTick,
            ttlTicks: profile.ttlTicks,
            source: BeliefSource.audible,
            confidence: .5,
            sound: sound,
          ),
        );
      }
    }
  }

  void markUnknown(GameEntityHandle target, {required int tick}) {
    if (tick < 0) throw RangeError.value(tick, 'tick');
    final entry = _entries[_targetKey(target)];
    if (entry != null && tick >= entry.belief.observedTick) {
      entry.unknownTick = tick;
    }
  }

  BeliefKnowledge stateAt(GameEntityHandle target, int tick) =>
      _state(_entries[_targetKey(target)], tick);
  BeliefKnowledge _state(_MemoryEntry? entry, int tick) {
    if (tick < 0) throw RangeError.value(tick, 'tick');
    if (entry == null || tick < entry.belief.observedTick) {
      return BeliefKnowledge.unobserved;
    }
    if (tick - entry.belief.observedTick > entry.belief.ttlTicks) {
      return BeliefKnowledge.expired;
    }
    if (entry.unknownTick != null &&
        tick >= entry.unknownTick! &&
        entry.unknownTick! > entry.belief.observedTick) {
      return BeliefKnowledge.unknown;
    }
    return tick == entry.belief.observedTick
        ? BeliefKnowledge.observed
        : BeliefKnowledge.unobserved;
  }

  List<AgedBelief> atTick(int tick) {
    if (tick < 0) throw RangeError.value(tick, 'tick');
    final list = <AgedBelief>[];
    for (final entry in _entries.values) {
      final age = tick - entry.belief.observedTick;
      if (age < 0 || age > entry.belief.ttlTicks) continue;
      list.add(
        AgedBelief._(
          entry.belief,
          age,
          math.max(
            0,
            entry.belief.confidence - age * profile.confidenceDecayPerTick,
          ),
          _state(entry, tick),
        ),
      );
    }
    list.sort((a, b) => a.key.compareTo(b.key));
    return List.unmodifiable(list);
  }

  void forget(GameEntityHandle target) {
    final removed = _entries.remove(_targetKey(target));
    if (removed != null) _bytes -= removed.bytes;
  }

  void reset(BrainReset reset) {
    final next = BeliefStore(identity: reset.identity, profile: profile);
    _identity = next.identity;
    _entries.clear();
    _bytes = _envelopeBytes;
  }

  MemorySnapshot snapshot({required int tick}) {
    final active = atTick(tick).map((b) => b.belief).toList();
    return MemorySnapshot._(identity, profile.hash, tick, active, {
      for (final belief in active)
        if (_entries[belief.key]!.unknownTick != null &&
            _entries[belief.key]!.unknownTick! <= tick)
          belief.key: _entries[belief.key]!.unknownTick!,
    });
  }

  void restore(MemorySnapshot snapshot, {required int tick}) {
    if (snapshot.identity != identity ||
        snapshot.profileHash != profile.hash ||
        snapshot._beliefs.length > profile.maxBeliefs ||
        tick < snapshot.savedTick) {
      throw ArgumentError(
        'Incompatible memory snapshot identity/profile/tick.',
      );
    }
    final shifted = BeliefStore(identity: identity, profile: profile);
    final delta = tick - snapshot.savedTick;
    for (final b in snapshot._beliefs) {
      if (!shifted._put(
        Belief._(
          key: b.key,
          target: b.target,
          position: b.position,
          positionFrame: b.positionFrame,
          observedTick: b.observedTick + delta,
          ttlTicks: b.ttlTicks,
          source: b.source,
          confidence: b.confidence,
          sound: b.sound == null
              ? null
              : HeardSound(
                  category: b.sound!.category,
                  observedTick: b.sound!.observedTick + delta,
                  eventTick: b.sound!.eventTick + delta,
                  bearingRadians: b.sound!.bearingRadians,
                  bearingUncertaintyRadians: b.sound!.bearingUncertaintyRadians,
                  distanceLowerMetres: b.sound!.distanceLowerMetres,
                  distanceUpperMetres: b.sound!.distanceUpperMetres,
                  obstructed: b.sound!.obstructed,
                ),
        ),
      )) {
        throw ArgumentError('Snapshot exceeds memory budget.');
      }
      final unknown = snapshot._unknownTicks[b.key];
      shifted._entries[b.key]!.unknownTick = unknown == null
          ? null
          : unknown + delta;
    }
    if (shifted._evictions != 0) {
      throw ArgumentError('Snapshot exceeds aggregate memory budget.');
    }
    _entries
      ..clear()
      ..addAll(shifted._entries);
    _bytes = shifted._bytes;
  }

  bool receive(
    TeamBeliefMessage message, {
    required TeamMemoryPolicy policy,
    required int tick,
    required double senderDistance,
    required bool permitted,
  }) {
    if (!permitted ||
        !senderDistance.isFinite ||
        senderDistance < 0 ||
        senderDistance > policy.range ||
        message.teamId != policy.teamId ||
        message.recipient != identity ||
        message.sender.episodeId != identity.episodeId ||
        tick < message.sentTick + policy.delayTicks ||
        tick - message.observedTick >
            math.min(message.ttlTicks, profile.ttlTicks)) {
      return false;
    }
    return observe(
      target: message.target,
      position: message.position,
      tick: message.observedTick,
      source: BeliefSource.team,
      confidence: message.confidence,
      ttlTicks: math.min(message.ttlTicks, profile.ttlTicks),
      positionFrame: message.sender.entity,
    );
  }
}

Map<String, Object> _memoryHandle(GameEntityHandle h) => {
  'id': h.id,
  'generation': h.generation,
};
GameEntityHandle _readMemoryHandle(dynamic value) => GameEntityHandle(
  (value as Map)['id'] as String,
  value['generation'] as int,
);
Map<String, Object> _memoryIdentity(BrainIdentity id) => {
  'episodeId': id.episodeId,
  'entity': _memoryHandle(id.entity),
  'modelHash': id.modelHash,
};

Map<String, Object?> _beliefJson(Belief b) => {
  'key': b.key,
  'target': b.target == null ? null : _memoryHandle(b.target!),
  'position': b.position?.storage,
  'positionFrame': _memoryHandle(b.positionFrame),
  'observedTick': b.observedTick,
  'ttlTicks': b.ttlTicks,
  'source': b.source.name,
  'confidence': b.confidence,
  'sound': b.sound == null
      ? null
      : {
          'category': b.sound!.category,
          'observedTick': b.sound!.observedTick,
          'eventTick': b.sound!.eventTick,
          'bearing': b.sound!.bearingRadians,
          'uncertainty': b.sound!.bearingUncertaintyRadians,
          'lower': b.sound!.distanceLowerMetres,
          'upper': b.sound!.distanceUpperMetres,
          'obstructed': b.sound!.obstructed,
        },
};
