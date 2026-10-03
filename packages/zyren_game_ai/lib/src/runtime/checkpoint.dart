part of '../../runtime.dart';

extension GameLevelAiPersistence on GameLevelAi {
  /// Pauses play and drains pending inference before capturing committed memory.
  /// The checkpoint stays paused so the host can inspect it before resuming.
  Future<GameSave> save() async {
    await _checkpointBoundary();
    return runtime().save();
  }

  /// Restores through the native codec transaction and refreshes entity handles.
  Future<void> restore(GameSave save) async {
    await _checkpointBoundary();
    runtime().restore(save);
  }

  Future<void> _checkpointBoundary() async {
    if (_closed || _session == null) {
      throw StateError('AI checkpoints require an initialized live session.');
    }
    if (!runtime().isPaused) runtime().pause();
    await Future.wait([
      for (final actor in _actors.values)
        if (actor.policy case final policy?) policy.quiesce(),
      ..._retiring,
    ]);
    if (_closed || !runtime().isPaused) {
      throw StateError('The host changed while preparing the checkpoint.');
    }
    if (_retirementError != null) {
      Error.throwWithStackTrace(_retirementError!, _retirementTrace!);
    }
  }

  void _applyCheckpoint(_AiCheckpoint checkpoint) {
    final session = _session!;
    final live = {
      for (final e in session.entities.entities) e.handle.id: e.handle,
    };
    GameEntityHandle? remap(GameEntityHandle old) =>
        checkpoint.handles[old.id] == old ? live[old.id] : null;
    for (final actor in _actors.values) {
      final saved = checkpoint.actors[actor.identity.entity.id]!;
      actor.scripted.restoreCommitted(
        saved.memory,
        identity: actor.identity,
        tick: session.tick,
        remap: remap,
      );
      final policy = actor.policy;
      if (policy != null) {
        policy.restoreCommitted(
          saved.policy!,
          identity: actor.identity,
          tick: session.tick,
          gameEpoch: session.epoch,
          controlEpoch: 0,
          paused: true,
          remap: remap,
        );
        actor.lastCountedVersion = policy.state.version;
      }
      if (actor.brain case final HybridBrain hybrid) {
        hybrid.restoreActiveSkill(
          identity: actor.identity,
          activeSkill: saved.activeSkill,
        );
      }
      actor.suspended = true;
    }
    onChanged?.call();
  }
}

final class _AiActorCheckpoint {
  final MemorySnapshot memory;
  final PolicyBrainCheckpoint? policy;
  final String? activeSkill;
  _AiActorCheckpoint(this.memory, this.policy, this.activeSkill);
}

final class _AiCheckpoint {
  final int tick;
  final Map<String, GameEntityHandle> handles;
  final Map<String, _AiActorCheckpoint> actors;
  _AiCheckpoint(this.tick, this.handles, this.actors);
}

final class _AiCodec extends GameStateCodec<_AiCheckpoint> {
  final GameLevelAi owner;
  _AiCodec(this.owner);
  @override
  String get id => 'game.ai.runtime';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) => {
    'tick': session.tick,
    'handles': {
      for (final e in session.entities.entities)
        e.handle.id: e.handle.generation,
    },
    'actors': {
      for (final actor in owner._actors.values)
        actor.identity.entity.id: {
          'profile': actor.definition.profile,
          'brain': actor.definition.brain,
          'memory': jsonDecode(
            actor.scripted.snapshotCommitted(tick: session.tick).encode(),
          ),
          if (actor.policy case final policy?)
            'policy': jsonDecode(
              policy.snapshotCommitted(tick: session.tick).encode(),
            ),
          if (actor.brain case final HybridBrain hybrid)
            'activeSkill': hybrid.activeSkill,
        },
    },
  };

  @override
  _AiCheckpoint prepare(GameSession session, Map<String, Object?> data) {
    final tick = data['tick'] as int;
    final generations = data['handles'] as Map;
    final records = data['actors'] as Map;
    if (tick < 0 ||
        tick > 9007199254740991 ||
        generations.length > 10000 ||
        records.length != owner._actors.length) {
      throw const FormatException('Invalid AI checkpoint size or tick.');
    }
    final handles = <String, GameEntityHandle>{
      for (final entry in generations.entries)
        entry.key as String: GameEntityHandle(
          entry.key as String,
          entry.value as int,
        ),
    };
    final live = {
      for (final e in session.entities.entities) e.handle.id: e.handle,
    };
    GameEntityHandle? remap(GameEntityHandle old) =>
        handles[old.id] == old ? live[old.id] : null;
    final actors = <String, _AiActorCheckpoint>{};
    for (final actor in owner._actors.values) {
      final record = records[actor.identity.entity.id] as Map;
      if (record['profile'] != actor.definition.profile ||
          record['brain'] != actor.definition.brain) {
        throw const FormatException(
          'Saved AI definition differs from the live actor.',
        );
      }
      final memory = MemorySnapshot.decode(jsonEncode(record['memory']));
      if (memory.savedTick != tick ||
          memory.identity.entity.id != actor.identity.entity.id) {
        throw const FormatException('AI memory tick or actor mismatch.');
      }
      BeliefStore(
        identity: actor.identity,
        profile: actor.scripted.memory.profile,
      ).restore(
        memory.remap(identity: actor.identity, remap: remap),
        tick: tick,
      );
      final rawPolicy = record['policy'];
      final policy = rawPolicy == null
          ? null
          : PolicyBrainCheckpoint.decode(jsonEncode(rawPolicy));
      if ((policy == null) != (actor.policy == null)) {
        throw const FormatException('Saved policy ownership differs.');
      }
      if (policy != null) {
        final brain = actor.policy!;
        if (policy.contractHash != brain.contract.hash ||
            policy.memory.savedTick != tick ||
            policy.memory.identity != memory.identity) {
          throw const FormatException(
            'Saved policy contract or identity differs.',
          );
        }
        brain.state.validateSnapshot(policy.state);
        BeliefStore(
          identity: actor.identity,
          profile: brain.memory.profile,
        ).restore(
          policy.memory.remap(identity: actor.identity, remap: remap),
          tick: tick,
        );
      }
      final skill = record['activeSkill'] as String?;
      if (skill != null &&
          (actor.brain is! HybridBrain ||
              !(actor.brain as HybridBrain).skillIds.contains(skill))) {
        throw const FormatException('Invalid saved hybrid skill.');
      }
      actors[actor.identity.entity.id] = _AiActorCheckpoint(
        memory,
        policy,
        skill,
      );
    }
    return _AiCheckpoint(tick, handles, actors);
  }

  @override
  void commit(GameSession session, _AiCheckpoint prepared) {
    if (prepared.tick != session.tick) {
      throw const FormatException('AI checkpoint tick differs from game save.');
    }
    owner._preparedCheckpoint = prepared;
  }
}
