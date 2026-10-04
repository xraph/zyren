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
    await Future.wait(_cameraJobs.toList());
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
  final GameAiAuthoringDefinition definition;
  final MemorySnapshot memory;
  final PolicyBrainCheckpoint? policy;
  final String? activeSkill;
  _AiActorCheckpoint(
    this.definition,
    this.memory,
    this.policy,
    this.activeSkill,
  );
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
  int get version => 2;
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
          if (actor.definition.cameraMode != null)
            'cameraMode': actor.definition.cameraMode,
          'brain': actor.definition.brain,
          'modelHash': actor.definition.modelHash,
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
        records.length > 256) {
      throw const FormatException('Invalid AI checkpoint size or tick.');
    }
    final handles = <String, GameEntityHandle>{
      for (final entry in generations.entries)
        entry.key as String: GameEntityHandle(
          entry.key as String,
          entry.value as int,
        ),
    };
    final actors = <String, _AiActorCheckpoint>{};
    for (final entry in records.entries) {
      final id = entry.key as String;
      final record = entry.value as Map;
      final recipe = owner.runtime().entityDefinition(id);
      if (recipe == null || !handles.containsKey(id)) {
        throw const FormatException('Saved AI has no prepared native recipe.');
      }
      final definition = owner._validateDefinition(id, recipe.components);
      if (record['profile'] != definition.profile ||
          record['cameraMode'] != definition.cameraMode ||
          record['brain'] != definition.brain ||
          record['modelHash'] != definition.modelHash) {
        throw const FormatException(
          'Saved AI definition differs from its recipe.',
        );
      }
      final memory = MemorySnapshot.decode(jsonEncode(record['memory']));
      final expectedModel =
          definition.modelHash ?? 'scripted-${definition.profile}';
      if (memory.savedTick != tick ||
          memory.identity.entity != handles[id] ||
          memory.identity.modelHash != expectedModel) {
        throw const FormatException('AI memory tick or actor mismatch.');
      }
      BeliefStore(identity: memory.identity).restore(memory, tick: tick);
      final rawPolicy = record['policy'];
      final policy = rawPolicy == null
          ? null
          : PolicyBrainCheckpoint.decode(jsonEncode(rawPolicy));
      final catalog = owner.policies[definition.modelHash];
      final hasPolicy =
          definition.brain != 'scripted' &&
          catalog != null &&
          owner._loadedModels.contains(definition.modelHash) &&
          catalog.fixedHz == owner.runtime().project.fixedHz &&
          catalog.contract.observation.hash ==
              definition.observationSpec.hash &&
          catalog.contract.decoder.spec.hash ==
              definition.createActions().spec.hash;
      if ((policy != null) != hasPolicy) {
        throw const FormatException('Saved policy ownership differs.');
      }
      if (policy != null) {
        final contract = catalog!.contract;
        if (policy.contractHash != contract.hash ||
            policy.memory.savedTick != tick ||
            policy.memory.identity != memory.identity) {
          throw const FormatException(
            'Saved policy contract or identity differs.',
          );
        }
        PolicyState(
          contract.model,
          maxBytes: contract.maxHiddenBytes,
        ).validateSnapshot(policy.state);
        BeliefStore(
          identity: memory.identity,
        ).restore(policy.memory, tick: tick);
      }
      final skill = record['activeSkill'] as String?;
      if (skill != null &&
          (definition.brain != 'hybrid' ||
              !hasPolicy ||
              !{'learned', 'scripted'}.contains(skill))) {
        throw const FormatException('Invalid saved hybrid skill.');
      }
      actors[id] = _AiActorCheckpoint(definition, memory, policy, skill);
    }
    return _AiCheckpoint(tick, handles, actors);
  }

  @override
  void commit(GameSession session, _AiCheckpoint prepared) {
    if (prepared.tick != session.tick) {
      throw const FormatException('AI checkpoint tick differs from game save.');
    }
    final candidateIds = session.entities.entities
        .map((e) => e.handle.id)
        .toSet();
    if (candidateIds.length != prepared.handles.length ||
        !candidateIds.containsAll(prepared.handles.keys)) {
      throw const FormatException(
        'Saved AI handle map differs from native topology.',
      );
    }
    final candidates = {
      for (final e in session.entities.entities)
        if (e.components.any((c) => c.type == 'game.ai')) e.handle.id: e,
    };
    if (candidates.length != prepared.actors.length) {
      throw const FormatException('Saved AI and native topology differ.');
    }
    for (final entry in candidates.entries) {
      final saved = prepared.actors[entry.key];
      final definition = GameAiAuthoringDefinition(
        entry.value.components.singleWhere((c) => c.type == 'game.ai').data,
      );
      if (saved == null ||
          definition.profile != saved.definition.profile ||
          definition.cameraMode != saved.definition.cameraMode ||
          definition.brain != saved.definition.brain ||
          definition.modelHash != saved.definition.modelHash) {
        throw const FormatException(
          'Saved entity changed its prepared AI definition.',
        );
      }
    }
    owner._preparedCheckpoint = prepared;
  }
}
