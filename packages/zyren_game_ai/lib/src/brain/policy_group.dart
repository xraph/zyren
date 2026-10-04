part of '../../zyren_game_ai.dart';

/// Actor brains share the host scheduler/cache and own separate recurrent state.
final class PolicyGroup {
  final String episodeId;
  final GameEntityTable entities;
  final MlScheduler ml;
  final int maxActors, maxStateBytes, maxRewardEvents;
  final _brains = <GameEntityHandle, PolicyBrain>{};
  final _contexts = <GameEntityHandle, BrainContext>{};
  final _rewards = <GameEntityHandle, double>{};
  final _rewardEvents = <String>{};
  int _revision = 0;
  bool _closed = false;
  PolicyGroup({
    required this.episodeId,
    required this.entities,
    required this.ml,
    this.maxActors = 64,
    this.maxStateBytes = 32 * 1024 * 1024,
    this.maxRewardEvents = 4096,
  }) {
    _name(episodeId);
    _bounded(maxActors, 256, 'policy actors');
    _bounded(maxStateBytes, 32 * 1024 * 1024, 'group state bytes');
    _bounded(maxRewardEvents, 4096, 'reward event ledger');
  }
  int get revision => _revision;
  bool get isClosed => _closed;
  List<GameEntityHandle> get actors => List.unmodifiable(_brains.keys);
  int get modelCount =>
      _brains.values.map((b) => b.contract.model.sha256).toSet().length;
  int get stateBytes =>
      _brains.values.fold(0, (n, b) => n + b.state.byteLength);
  PolicyBrain? brainFor(GameEntityHandle actor) => _brains[actor];
  PolicyState? stateFor(GameEntityHandle actor) => _brains[actor]?.state;
  PolicyBrain join(
    BrainIdentity identity,
    PolicyContract contract, {
    bool autoRequest = true,
  }) {
    if (identity.episodeId != episodeId) {
      throw ArgumentError('Foreign policy episode.');
    }
    if (_closed ||
        _brains.containsKey(identity.entity) ||
        _brains.length >= maxActors) {
      throw StateError('Policy group closed, duplicate or full.');
    }
    _modelPin(contract);
    final brain = PolicyBrain(
      identity: identity,
      contract: contract,
      ml: ml,
      entities: entities,
      autoRequest: autoRequest,
    );
    if (stateBytes + brain.state.byteLength > maxStateBytes) {
      throw StateError('Group recurrent-state budget exceeded.');
    }
    _brains[identity.entity] = brain;
    _rewards[identity.entity] = 0;
    _revision++;
    return brain;
  }

  Future<void> leave(GameEntityHandle actor) async {
    final brain = _brains.remove(actor);
    if (brain == null) return;
    _contexts.remove(actor);
    _rewards.remove(actor);
    _revision++;
    await brain.close();
  }

  void record(BrainContext context) {
    final brain = _brains[context.identity.entity];
    if (_closed ||
        brain?.identity != context.identity ||
        !entities.isAlive(context.identity.entity) ||
        (_contexts[context.identity.entity]?.tick ?? -1) > context.tick) {
      throw ArgumentError('Foreign or stale group context.');
    }
    _contexts[context.identity.entity] = context;
    _revision++;
  }

  void reset(GameEntityHandle actor) {
    final brain = _brains[actor];
    if (_closed || brain == null || !entities.isAlive(actor)) {
      throw StateError('Policy actor unavailable.');
    }
    brain.reset(BrainReset(brain.identity, BrainResetReason.manual));
    _contexts.remove(actor);
    _revision++;
  }

  Future<void> selectModel(
    GameEntityHandle actor,
    PolicyContract contract,
  ) async {
    final old = _brains[actor];
    if (_closed || old == null || !entities.isAlive(actor)) {
      throw StateError('Policy actor unavailable.');
    }
    _modelPin(contract);
    final identity = BrainIdentity(
      episodeId: old.identity.episodeId,
      entity: actor,
      modelHash: contract.model.sha256,
    );
    final next = PolicyBrain(
      identity: identity,
      contract: contract,
      ml: ml,
      entities: entities,
      autoRequest: old.autoRequest,
    );
    if (stateBytes - old.state.byteLength + next.state.byteLength >
        maxStateBytes) {
      throw StateError('Group recurrent-state budget exceeded.');
    }
    _brains[actor] = next;
    _contexts.remove(actor);
    _revision++;
    await old.close();
  }

  void _modelPin(PolicyContract contract) {
    if (_brains.values.any(
      (brain) =>
          brain.contract.model.sha256 == contract.model.sha256 &&
          brain.contract.model.encode() != contract.model.encode(),
    )) {
      throw ArgumentError(
        'Shared weights require the same immutable model manifest.',
      );
    }
  }

  /// The host credits authored reward events. No passive tool can call this.
  bool creditTeamReward(
    GameTeam team, {
    required String eventId,
    required double reward,
  }) {
    _name(eventId);
    if (_closed ||
        !reward.isFinite ||
        reward.abs() > 1000000 ||
        _rewardEvents.contains(eventId) ||
        _rewardEvents.length >= maxRewardEvents ||
        !identical(team.entities, entities)) {
      return false;
    }
    final admitted = team.members
        .where((m) => _brains[m.entity]?.identity == m)
        .toList();
    if (admitted.isEmpty ||
        admitted.any(
          (m) =>
              !((_rewards[m.entity] ?? 0) + reward).isFinite ||
              ((_rewards[m.entity] ?? 0) + reward).abs() > 1e12,
        )) {
      return false;
    }
    _rewardEvents.add(eventId);
    for (final member in admitted) {
      _rewards[member.entity] = (_rewards[member.entity] ?? 0) + reward;
    }
    _revision++;
    return true;
  }

  double rewardFor(GameEntityHandle actor) => _rewards[actor] ?? 0;
  Map<String, Object?> inspect(GameEntityHandle actor, {int valueLimit = 128}) {
    _bounded(valueLimit, 256, 'diagnostic values');
    final brain = _brains[actor], context = _contexts[actor];
    if (brain == null || _closed || !entities.isAlive(actor)) {
      throw StateError('Policy actor unavailable.');
    }
    final frame = brain._frame;
    final request = brain.activeRequest, staged = brain.decisions._staged;
    return {
      'actor': _memoryHandle(actor),
      'episodeId': brain.identity.episodeId,
      'modelHash': brain.identity.modelHash,
      'contractHash': brain.contract.hash,
      'stateVersion': brain.state.version,
      'stateEpoch': brain.state.epoch,
      'stateBytes': brain.state.byteLength,
      'pending': brain.hasPending,
      'gameEpoch': brain.decisions.gameEpoch,
      'controlEpoch': brain.decisions.controlEpoch,
      'latencyTicks': brain.contract.latencyTicks,
      'cadenceTicks': brain.contract.cadenceTicks,
      'applicationTick': request?.applicationTick ?? staged?.applyTick,
      'deadlineTick': request?.deadlineTick ?? staged?.applyTick,
      'request': request == null
          ? null
          : {
              'id': request.id,
              'modelHash': request.modelHash,
              'observationTick': request.observationTick,
              'applicationTick': request.applicationTick,
              'deadlineTick': request.deadlineTick,
              'deadline': request.deadline?.toUtc().toIso8601String(),
            },
      'beliefs': brain.memory
          .atTick(ml.currentTick())
          .take(16)
          .map(
            (b) => {
              'target': b.target == null ? null : _memoryHandle(b.target!),
              'positionFrame': _memoryHandle(b.positionFrame),
              'observedTick': b.observedTick,
              'ageTicks': b.ageTicks,
              'knowledge': b.knowledge.name,
              'source': b.source.name,
              'confidence': b.confidence,
            },
          )
          .toList(),
      'observation': frame == null
          ? null
          : {
              'tick': frame.tick,
              'worldRevision': frame.worldRevision,
              'schemaHash': frame.schemaHash,
              'sensorProfileHash': frame.sensorProfileHash,
              'values': frame.tensor.float32Values.take(valueLimit).toList(),
              'truncated': frame.tensor.byteLength ~/ 4 > valueLimit,
            },
      'goals':
          context?.goals
              .take(16)
              .map(
                (g) => {
                  'id': g.id,
                  'skill': g.skill,
                  'target': g.target == null ? null : _memoryHandle(g.target!),
                  'priority': g.priority,
                  'utility': g.utility,
                },
              )
              .toList() ??
          [],
      'failure': brain.lastFailure?.status.name,
      'receipts': brain.decisions.receipts.reversed
          .take(16)
          .map(
            (r) => {
              'observationTick': r.observationTick,
              'applyTick': r.applyTick,
              'completedTick': r.completedTick,
              'applicationTick': r.applicationTick,
              'stateVersion': r.stateVersion,
              'modelHash': r.modelHash,
              'accepted': r.accepted,
              'reason': r.reason,
            },
          )
          .toList(),
      'reward': rewardFor(actor),
    };
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final brains = _brains.values.toList();
    _brains.clear();
    _contexts.clear();
    _rewards.clear();
    _revision++;
    await Future.wait(brains.map((b) => b.close()));
  }
}
