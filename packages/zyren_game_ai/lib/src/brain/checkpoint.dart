part of '../../zyren_game_ai.dart';

/// Owned little-endian storage. Encoded state is capped before allocation.
final class PolicyStateSnapshot {
  final String modelHash;
  final int version;
  final MlTensorMap tensors;
  PolicyStateSnapshot._(this.modelHash, this.version, MlTensorMap tensors)
    : tensors = Map.unmodifiable(tensors);
  String encode() => jsonEncode({
    'schema': 1,
    'modelHash': modelHash,
    'version': version,
    'tensors': {
      for (final e in tensors.entries)
        e.key: {
          'dtype': e.value.dtype.name,
          'shape': e.value.shape,
          'bytes': base64Encode(e.value.bytes),
        },
    },
  });
  factory PolicyStateSnapshot.decode(String source) {
    _checkpointBytes(source, 1500000);
    final json = jsonDecode(source) as Map<String, dynamic>;
    final hash = json['modelHash'] as String, version = json['version'] as int;
    final raw = json['tensors'] as Map<String, dynamic>;
    if (json['schema'] != 1 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) ||
        version < 0 ||
        version > 9007199254740991 ||
        raw.length > 64) {
      throw const FormatException('Invalid recurrent state envelope.');
    }
    final tensors = <String, MlTensor>{};
    var total = 0;
    for (final entry in raw.entries) {
      _name(entry.key);
      final tensor = entry.value as Map<String, dynamic>;
      final dtype = MlDtype.values.byName(tensor['dtype'] as String);
      final shape = (tensor['shape'] as List).cast<int>();
      final bytes = mlTensorByteLength(dtype, shape);
      total += bytes;
      final encoded = tensor['bytes'] as String;
      if (total > 1048576 || encoded.length != ((bytes + 2) ~/ 3) * 4) {
        throw const FormatException('Recurrent tensor storage exceeds budget.');
      }
      final value = MlTensor(dtype, shape, base64Decode(encoded));
      if (!value.isFinite) {
        throw const FormatException('Nonfinite recurrent state.');
      }
      tensors[entry.key] = value;
    }
    return PolicyStateSnapshot._(hash, version, tensors);
  }
}

void _checkpointBytes(String source, int max) {
  if (source.length > max || utf8.encode(source).length > max) {
    throw const FormatException('Brain checkpoint byte limit exceeded.');
  }
}

final class PolicyBrainCheckpoint {
  final String contractHash;
  final PolicyStateSnapshot state;
  final MemorySnapshot memory;
  PolicyBrainCheckpoint._(this.contractHash, this.state, this.memory);
  String encode() => jsonEncode({
    'schema': 1,
    'contractHash': contractHash,
    'state': jsonDecode(state.encode()),
    'memory': jsonDecode(memory.encode()),
  });
  factory PolicyBrainCheckpoint.decode(String source) {
    _checkpointBytes(source, 3000000);
    final json = jsonDecode(source) as Map<String, dynamic>;
    final hash = json['contractHash'] as String;
    if (json['schema'] != 1 || !RegExp(r'^[0-9a-f]{64}$').hasMatch(hash)) {
      throw const FormatException('Invalid policy checkpoint envelope.');
    }
    return PolicyBrainCheckpoint._(
      hash,
      PolicyStateSnapshot.decode(jsonEncode(json['state'])),
      MemorySnapshot.decode(jsonEncode(json['memory'])),
    );
  }
}

extension PolicyBrainPersistence on PolicyBrain {
  PolicyBrainCheckpoint snapshotCommitted({required int tick}) {
    if (_closed || _actualJobs.isNotEmpty || hasPending) {
      throw StateError('Quiesce the brain before checkpointing.');
    }
    return PolicyBrainCheckpoint._(
      contract.hash,
      state.snapshot(),
      memory.snapshot(tick: tick),
    );
  }

  void restoreCommitted(
    PolicyBrainCheckpoint checkpoint, {
    required BrainIdentity identity,
    required int tick,
    required int gameEpoch,
    required int controlEpoch,
    required bool paused,
    required GameEntityHandle? Function(GameEntityHandle old) remap,
  }) {
    if (_closed || _actualJobs.isNotEmpty || hasPending) {
      throw StateError('Quiesce the brain before restoring.');
    }
    if (checkpoint.contractHash != contract.hash ||
        identity.modelHash != contract.model.sha256 ||
        !entities.isAlive(identity.entity) ||
        gameEpoch < 0 ||
        controlEpoch < 0) {
      throw ArgumentError(
        'Incompatible policy checkpoint contract/actor/epochs.',
      );
    }
    state.validateSnapshot(checkpoint.state);
    final mapped = checkpoint.memory.remap(identity: identity, remap: remap);
    final checked = BeliefStore(identity: identity, profile: memory.profile)
      ..restore(mapped, tick: tick);
    // All caller data has been validated before mutating committed state.
    reset(BrainReset(identity, BrainResetReason.manual));
    decisions.synchronize(
      gameEpoch: gameEpoch,
      controlEpoch: controlEpoch,
      paused: paused,
    );
    state.restoreSnapshot(checkpoint.state);
    memory.restore(checked.snapshot(tick: tick), tick: tick);
  }
}

extension MemorySnapshotRemapping on MemorySnapshot {
  /// Missing targets remain historical handles. No live world state is read.
  MemorySnapshot remap({
    required BrainIdentity identity,
    required GameEntityHandle? Function(GameEntityHandle old) remap,
  }) {
    if (identity.modelHash != this.identity.modelHash ||
        remap(this.identity.entity) != identity.entity) {
      throw ArgumentError('Memory actor/model remapping mismatch.');
    }
    final handles = <GameEntityHandle, GameEntityHandle>{
      this.identity.entity: identity.entity,
    };
    GameEntityHandle mapped(GameEntityHandle old) =>
        handles.putIfAbsent(old, () => remap(old) ?? old);
    final unknown = <String, int>{}, beliefs = <Belief>[];
    for (final belief in _beliefs) {
      final target = belief.target == null ? null : mapped(belief.target!);
      final key = target == null
          ? belief.key
          : 'entity:${target.id}@${target.generation}';
      beliefs.add(
        Belief._(
          key: key,
          target: target,
          position: belief.position,
          positionFrame: mapped(belief.positionFrame),
          observedTick: belief.observedTick,
          ttlTicks: belief.ttlTicks,
          source: belief.source,
          confidence: belief.confidence,
          sound: belief.sound,
        ),
      );
      if (_unknownTicks[belief.key] case final int tick) {
        unknown[key] = tick;
      }
    }
    if (beliefs.map((b) => b.key).toSet().length != beliefs.length) {
      throw ArgumentError(
        'Memory remapping merged distinct historical targets.',
      );
    }
    return MemorySnapshot._(identity, profileHash, savedTick, beliefs, unknown);
  }
}

extension ScriptedBrainPersistence on ScriptedBrain {
  MemorySnapshot snapshotCommitted({required int tick}) {
    if (_closed) throw StateError('Brain is closed.');
    return memory.snapshot(tick: tick);
  }

  /// Rebuilds the deterministic runner on its next decision from saved beliefs.
  void restoreCommitted(
    MemorySnapshot checkpoint, {
    required BrainIdentity identity,
    required int tick,
    required GameEntityHandle? Function(GameEntityHandle old) remap,
  }) {
    if (_closed || !_entities.isAlive(identity.entity)) {
      throw StateError('Brain requires a live actor.');
    }
    final mapped = checkpoint.remap(identity: identity, remap: remap);
    final checked = BeliefStore(identity: identity, profile: memory.profile)
      ..restore(mapped, tick: tick);
    reset(BrainReset(identity, BrainResetReason.manual));
    memory.restore(checked.snapshot(tick: tick), tick: tick);
  }
}

extension HybridBrainPersistence on HybridBrain {
  /// Children are restored independently before restoring the active selector.
  /// The next choice of the same skill does not reset its committed state.
  void restoreActiveSkill({
    required BrainIdentity identity,
    String? activeSkill,
  }) {
    if (_closed || (activeSkill != null && !_skills.containsKey(activeSkill))) {
      throw StateError('Invalid hybrid checkpoint active skill.');
    }
    for (final skill in _skills.values) {
      final childIdentity = switch (skill) {
        PolicyBrain brain => brain.identity,
        ScriptedBrain brain => brain.identity,
        _ => throw StateError(
          'Custom hybrid skill has no checkpoint contract.',
        ),
      };
      if (childIdentity != identity ||
          skill is PolicyBrain &&
              (skill.hasPending || skill._actualJobs.isNotEmpty)) {
        throw StateError(
          'Restore quiescent children before the hybrid selector.',
        );
      }
    }
    _identity = identity;
    _active = activeSkill;
    _frame = null;
    selector.reset();
  }
}
