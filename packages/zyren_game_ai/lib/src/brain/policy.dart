part of '../../zyren_game_ai.dart';

abstract interface class PolicyObservationEncoder {
  String get id;
  MlTensor encode(ObservationFrame frame);
}

final class FramePolicyEncoder implements PolicyObservationEncoder {
  const FramePolicyEncoder();
  @override
  String get id => 'frame-tensor-v1';
  @override
  MlTensor encode(ObservationFrame frame) => frame.tensor;
}

/// Model/schema/time pins shared by deployment and training. No acceptance claim.
final class PolicyContract {
  final MlModelManifest model;
  final ObservationSpec observation;
  final ActionDecoder decoder;
  final PolicyObservationEncoder encoder;
  final String observationInput, continuousOutput;
  final String? discreteOutput;
  final int latencyTicks, cadenceTicks, maxHoldTicks, maxHiddenBytes;
  PolicyContract({
    required this.model,
    required this.observation,
    required this.decoder,
    this.encoder = const FramePolicyEncoder(),
    this.observationInput = 'observation',
    this.continuousOutput = 'action',
    this.discreteOutput,
    this.latencyTicks = 1,
    this.cadenceTicks = 1,
    this.maxHoldTicks = 0,
    this.maxHiddenBytes = 1048576,
  }) {
    _name(encoder.id);
    _bounded(latencyTicks, 3600, 'latencyTicks');
    _bounded(cadenceTicks, 3600, 'cadenceTicks');
    _bounded(maxHoldTicks, 3600, 'maxHoldTicks', zero: true);
    _bounded(maxHiddenBytes, 1048576, 'maxHiddenBytes');
    final input = model.inputs
        .where((s) => s.name == observationInput)
        .firstOrNull;
    final output = model.outputs
        .where((s) => s.name == continuousOutput)
        .firstOrNull;
    if (input == null ||
        input.dtype != MlDtype.float32 ||
        input.shape.length < 2 ||
        input.shape.length > 4 ||
        input.shape.skip(1).any((dimension) => dimension <= 0) ||
        model.recurrent.containsKey(observationInput) ||
        model.inputs.any(
          (s) =>
              s.name != observationInput &&
              !model.recurrent.containsKey(s.name),
        ) ||
        output == null ||
        output.dtype != MlDtype.float32 ||
        output.shape.length != 2 ||
        output.shape[1] != decoder.spec.continuous.length ||
        model.recurrent.containsValue(continuousOutput) ||
        (encoder is FramePolicyEncoder &&
            (input.shape.length != 2 || input.shape[1] != observation.width)) ||
        observation.latencyTicks != latencyTicks ||
        observation.cadenceTicks != cadenceTicks) {
      throw ArgumentError('Policy model/schema/time binding mismatch.');
    }
    if (decoder.spec.branches.isNotEmpty) {
      final discrete = model.outputs
          .where((s) => s.name == discreteOutput)
          .firstOrNull;
      final logits = decoder.spec.branches.fold<int>(
        0,
        (n, b) => n + b.choices.length,
      );
      if (discrete == null ||
          discrete.shape.length != 2 ||
          !(discrete.dtype == MlDtype.int64 &&
                  discrete.shape[1] == decoder.spec.branches.length ||
              discrete.dtype == MlDtype.float32 &&
                  discrete.shape[1] == logits)) {
        throw ArgumentError('Discrete tensor binding mismatch.');
      }
    } else if (discreteOutput != null) {
      throw ArgumentError('Unexpected discrete policy output.');
    }
    if (encoder case final CameraPolicyEncoder camera) {
      if (input.shape.length != 4 ||
          input.shape[1] != camera.profile.channels ||
          input.shape[2] != camera.profile.height ||
          input.shape[3] != camera.profile.width) {
        throw ArgumentError('Camera encoder/model image shape mismatch.');
      }
    }
    PolicyState(model, maxBytes: maxHiddenBytes);
  }
  String get hash => _hash(toJson());
  Map<String, Object?> toJson() => {
    'modelManifest': jsonDecode(model.encode()),
    'observationSchema': observation.toJson(),
    'actionSchema': decoder.spec.toJson(),
    'encoder': encoder.id,
    'observationInput': observationInput,
    'continuousOutput': continuousOutput,
    'discreteOutput': discreteOutput,
    'latencyTicks': latencyTicks,
    'cadenceTicks': cadenceTicks,
    'maxHoldTicks': maxHoldTicks,
    'maxHiddenBytes': maxHiddenBytes,
  };

  PolicyAction? _action(MlTensorMap tensors, List<List<bool>>? legality) {
    final continuous = tensors[continuousOutput];
    final expected = model.outputs.firstWhere(
      (s) => s.name == continuousOutput,
    );
    if (continuous == null ||
        continuous.shape.firstOrNull != 1 ||
        !expected.accepts(continuous)) {
      return null;
    }
    final choices = <int>[];
    if (discreteOutput != null) {
      final tensor = tensors[discreteOutput];
      final spec = model.outputs.firstWhere((s) => s.name == discreteOutput);
      if (tensor == null ||
          tensor.shape.firstOrNull != 1 ||
          !spec.accepts(tensor) ||
          legality == null) {
        return null;
      }
      final masks = _policyLegality(legality, decoder.spec);
      if (tensor.dtype == MlDtype.int64) {
        choices.addAll(tensor.int64Values);
      } else {
        final logits = tensor.float32Values;
        var offset = 0;
        for (var branch = 0; branch < masks.length; branch++) {
          var best = -1;
          for (var choice = 0; choice < masks[branch].length; choice++) {
            if (masks[branch][choice] &&
                (best == -1 ||
                    logits[offset + choice] > logits[offset + best])) {
              best = choice;
            }
          }
          if (best == -1) return null;
          choices.add(best);
          offset += masks[branch].length;
        }
      }
    }
    final result = PolicyAction(continuous.float32Values, choices);
    return decoder.decode(result, legality: legality) == null ? null : result;
  }
}

final class PolicyFailure {
  final MlOutcomeStatus status;
  final int observationTick, applyTick, completedTick;
  final String message;
  PolicyFailure._observation(int tick, int latency, Object error)
    : status = MlOutcomeStatus.invalid,
      observationTick = tick,
      applyTick = tick + latency,
      completedTick = tick,
      message = error.toString().substring(
        0,
        math.min(4096, error.toString().length),
      );
  PolicyFailure._(MlOutcome result)
    : status = result.status,
      observationTick = result.observationTick,
      applyTick = result.applicationTick,
      completedTick = result.completedTick,
      message = (result.message ?? result.status.name).substring(
        0,
        math.min(4096, (result.message ?? result.status.name).length),
      );
}

/// One unresolved recurrent request per actor; weights and batching are shared.
final class PolicyBrain implements GameBrain {
  BrainIdentity _identity;
  BrainIdentity get identity => _identity;
  final PolicyContract contract;
  final MlScheduler ml;
  final GameEntityTable entities;
  final PolicyState state;
  final BeliefStore memory;
  late final DecisionScheduler decisions;
  ObservationFrame? _frame;
  Future<BrainDecision?>? _pending;
  String? _requestId;
  int _serial = 0, _sequence = 0, _lastDecisionTick = -1;
  bool _closed = false;
  PolicyFailure? lastFailure;
  PolicyBrain({
    required BrainIdentity identity,
    required this.contract,
    required this.ml,
    required this.entities,
    MemoryProfile? memoryProfile,
  }) : _identity = identity,
       state = PolicyState(contract.model, maxBytes: contract.maxHiddenBytes),
       memory = BeliefStore(identity: identity, profile: memoryProfile) {
    if (identity.modelHash != contract.model.sha256 ||
        !entities.isAlive(identity.entity)) {
      throw ArgumentError('Policy identity/model/live actor mismatch.');
    }
    decisions = DecisionScheduler(
      identity: identity,
      entities: entities,
      decoder: contract.decoder,
      state: state,
      maxHoldTicks: contract.maxHoldTicks,
    );
  }
  bool get hasPending => _pending != null || decisions.hasStaged;
  Future<BrainDecision?>? get pending => _pending;
  @override
  void observe(ObservationFrame frame) {
    if (_closed) throw StateError('Policy brain is closed.');
    if (frame.entity != identity.entity ||
        frame.episodeId != identity.episodeId ||
        frame.schemaHash != contract.observation.hash ||
        (_frame != null && frame.tick < _frame!.tick)) {
      throw ArgumentError('Foreign or stale policy observation.');
    }
    memory.observeFrame(frame);
    _frame = frame;
  }

  Future<BrainDecision?> request(
    BrainContext context, {
    List<List<bool>>? legality,
    GameEntityHandle? target,
    DateTime? deadline,
  }) {
    if (_closed) throw StateError('Policy brain is closed.');
    if (context.identity != identity ||
        context.actionSpec.hash != contract.decoder.spec.hash) {
      throw ArgumentError('Foreign policy context.');
    }
    synchronize(
      gameEpoch: context.gameEpoch,
      controlEpoch: context.controlEpoch,
      paused: decisions.paused,
    );
    final frame = _frame;
    if (ml.currentTick() != context.tick) {
      throw ArgumentError(
        'Policy request must use the current authoritative tick.',
      );
    }
    if (hasPending ||
        decisions.paused ||
        frame == null ||
        frame.tick != context.tick ||
        frame.tick % contract.cadenceTicks != 0 ||
        !entities.isAlive(identity.entity) ||
        target != null &&
            (!context.validTargets.contains(target) ||
                !entities.isAlive(target))) {
      return Future.value(null);
    }
    final masks = legality == null
        ? null
        : _policyLegality(legality, contract.decoder.spec);
    final MlTensor encoded;
    try {
      encoded = contract.encoder.encode(frame);
      final spec = contract.model.inputs.firstWhere(
        (s) => s.name == contract.observationInput,
      );
      if (encoded.shape.firstOrNull != 1 || !spec.accepts(encoded)) {
        throw ArgumentError('Encoded observation tensor mismatch.');
      }
    } catch (error) {
      lastFailure = PolicyFailure._observation(
        context.tick,
        contract.latencyTicks,
        error,
      );
      return Future.value(null);
    }
    final serial = _serial, version = state.version, who = identity;
    final gameEpoch = decisions.gameEpoch,
        controlEpoch = decisions.controlEpoch;
    final id =
        '${who.episodeId}:${who.entity.id}@${who.entity.generation}:${++_sequence}:$serial';
    _requestId = id;
    final applyTick = frame.tick + contract.latencyTicks;
    final request = MlRequest(
      id: id,
      model: contract.model,
      modelHash: who.modelHash,
      actorToken: who,
      observationTick: frame.tick,
      applicationTick: applyTick,
      deadlineTick: applyTick,
      deadline: deadline,
      tensors: {contract.observationInput: encoded, ...state.tensors},
    );
    final job = _run(
      request,
      who,
      serial,
      version,
      state.epoch,
      gameEpoch,
      controlEpoch,
      masks,
      target,
    );
    _pending = job;
    return job;
  }

  Future<BrainDecision?> _run(
    MlRequest request,
    BrainIdentity who,
    int serial,
    int version,
    int stateEpoch,
    int gameEpoch,
    int controlEpoch,
    List<List<bool>>? legality,
    GameEntityHandle? target,
  ) async {
    try {
      final result = await ml.submit(request);
      if (!_closed &&
          serial == _serial &&
          result.status != MlOutcomeStatus.ok) {
        lastFailure = PolicyFailure._(result);
      }
      if (_closed ||
          serial != _serial ||
          identity != who ||
          result.status != MlOutcomeStatus.ok ||
          result.actorToken != who ||
          result.modelHash != who.modelHash ||
          result.observationTick != request.observationTick ||
          result.applicationTick != request.applicationTick ||
          result.completedTick < request.observationTick ||
          result.completedTick > request.applicationTick ||
          state.version != version ||
          state.epoch != stateEpoch) {
        return null;
      }
      final action = contract._action(result.tensors, legality);
      final hidden = <String, MlTensor>{};
      for (final entry in contract.model.recurrent.entries) {
        final tensor = result.tensors[entry.value];
        if (tensor == null) return null;
        hidden[entry.key] = tensor;
      }
      if (action == null || !state.accepts(hidden)) return null;
      final decision = BrainDecision.policy(
        identity: who,
        observationTick: request.observationTick,
        applyTick: request.applicationTick,
        decisionTick: result.completedTick,
        actionSchemaHash: contract.decoder.spec.hash,
        action: action,
        nextHiddenState: hidden,
        baseStateVersion: version,
        stateEpoch: stateEpoch,
        gameEpoch: gameEpoch,
        controlEpoch: controlEpoch,
        target: target,
      );
      return decisions.stage(decision, legality: legality) ? decision : null;
    } finally {
      if (serial == _serial && _requestId == request.id) {
        _pending = null;
        _requestId = null;
      }
    }
  }

  @override
  BrainDecision decide(BrainContext context) {
    if (_closed) throw StateError('Policy brain is closed.');
    if (context.identity != identity ||
        context.actionSpec.hash != contract.decoder.spec.hash ||
        context.tick <= _lastDecisionTick) {
      throw ArgumentError('Invalid policy decision context.');
    }
    synchronize(
      gameEpoch: context.gameEpoch,
      controlEpoch: context.controlEpoch,
      paused: decisions.paused,
    );
    _lastDecisionTick = context.tick;
    final decision = decisions.atTick(
      context.tick,
      legality: context.legality,
      validTargets: context.validTargets,
    );
    if (!hasPending && !decisions.paused) {
      // The host may also explicitly await request() before advancing game ticks.
      unawaited(
        request(
          context,
          legality: context.legality,
          target: context.goals.firstOrNull?.target,
        ).catchError((Object _) => null),
      );
    }
    return decision;
  }

  void synchronize({
    required int gameEpoch,
    required int controlEpoch,
    required bool paused,
  }) {
    if (decisions.gameEpoch != gameEpoch ||
        decisions.controlEpoch != controlEpoch ||
        decisions.paused != paused) {
      invalidatePending();
    }
    decisions.synchronize(
      gameEpoch: gameEpoch,
      controlEpoch: controlEpoch,
      paused: paused,
    );
  }

  void invalidatePending() {
    if (_requestId != null) ml.cancel(_requestId!);
    _serial++;
    _frame = null;
    _lastDecisionTick = -1;
    _pending = null;
    _requestId = null;
    decisions.invalidatePending();
  }

  @override
  void reset(BrainReset reset) {
    if (_closed) throw StateError('Policy brain is closed.');
    if (reset.identity.modelHash != contract.model.sha256) {
      throw ArgumentError('Construct a new brain for a model swap.');
    }
    invalidatePending();
    _identity = reset.identity;
    decisions.reset(identity);
    memory.reset(reset);
    lastFailure = null;
    _frame = null;
    _lastDecisionTick = -1;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final waiting = _pending;
    invalidatePending();
    _frame = null;
    memory.reset(BrainReset(identity, BrainResetReason.despawned));
    await waiting;
  }
}
