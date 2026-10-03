part of '../../zyren_game_ai.dart';

final class PolicyReceipt {
  final int observationTick,
      applyTick,
      completedTick,
      applicationTick,
      stateVersion;
  final String modelHash, reason;
  final bool accepted;
  PolicyReceipt(
    this.observationTick,
    this.applyTick,
    this.completedTick,
    this.applicationTick,
    this.stateVersion,
    this.modelHash,
    this.reason,
    this.accepted,
  );
}

/// Exact due tick admission, with atomic action/state commit and bounded holds.
final class DecisionScheduler {
  BrainIdentity _identity;
  BrainIdentity get identity => _identity;
  final GameEntityTable entities;
  final ActionDecoder decoder;
  final PolicyState state;
  final int maxHoldTicks;
  int _gameEpoch = 0, _controlEpoch = 0;
  bool _paused = false;
  int get gameEpoch => _gameEpoch;
  int get controlEpoch => _controlEpoch;
  bool get paused => _paused;
  BrainDecision? _staged, _last;
  int _lastAcceptedTick = -1;
  final List<PolicyReceipt> _receipts = [];
  List<PolicyReceipt> get receipts => List.unmodifiable(_receipts);
  bool get hasStaged => _staged != null;
  late DecodedAction currentAction = decoder.fallback;
  DecisionScheduler({
    required BrainIdentity identity,
    required this.entities,
    required this.decoder,
    required this.state,
    this.maxHoldTicks = 0,
  }) : _identity = identity {
    _bounded(maxHoldTicks, 3600, 'maxHoldTicks', zero: true);
    if (identity.modelHash != state.model.sha256) {
      throw ArgumentError('State model identity mismatch.');
    }
  }
  bool _pins(BrainDecision d) =>
      !paused &&
      d.isApplicable(entities, identity) &&
      d.gameEpoch == gameEpoch &&
      d.controlEpoch == controlEpoch &&
      d.actionSchemaHash == decoder.spec.hash &&
      d.baseStateVersion == state.version &&
      d.stateEpoch == state.epoch &&
      d.observationTick >= 0 &&
      d.decisionTick >= d.observationTick &&
      d.decisionTick <= d.applyTick &&
      d.applyTick >= d.observationTick &&
      d.policyAction != null;
  bool stage(BrainDecision d, {List<List<bool>>? legality}) {
    if (_staged != null ||
        !_pins(d) ||
        !state.accepts(d.nextHiddenState) ||
        decoder.decode(d.policyAction!, legality: legality) == null) {
      return false;
    }
    _staged = d;
    return true;
  }

  bool accept(
    BrainDecision d, {
    required int tick,
    List<List<bool>>? legality,
    Set<GameEntityHandle> validTargets = const {},
  }) {
    final decoded = d.policyAction == null
        ? null
        : decoder.decode(d.policyAction!, legality: legality);
    final accepted =
        (decoder.spec.branches.isEmpty || legality != null) &&
        _pins(d) &&
        (d.target == null || validTargets.contains(d.target)) &&
        tick == d.applyTick &&
        tick > _lastAcceptedTick &&
        decoded != null &&
        state.accepts(d.nextHiddenState) &&
        state._commit(d.nextHiddenState, d.baseStateVersion);
    if (accepted) {
      currentAction = decoded;
      _last = d;
      _lastAcceptedTick = tick;
    }
    _record(d, tick, accepted ? 'accepted' : 'rejected', accepted);
    return accepted;
  }

  void _record(BrainDecision d, int tick, String reason, bool accepted) {
    if (_receipts.length == 256) _receipts.removeAt(0);
    _receipts.add(
      PolicyReceipt(
        d.observationTick,
        d.applyTick,
        d.decisionTick,
        tick,
        state.version,
        d.identity.modelHash,
        reason,
        accepted,
      ),
    );
  }

  BrainDecision atTick(
    int tick, {
    List<List<bool>>? legality,
    Set<GameEntityHandle> validTargets = const {},
  }) {
    if (tick < 0) throw RangeError.value(tick, 'tick');
    final due = _staged;
    if (due != null && tick >= due.applyTick) {
      _staged = null;
      final masks = legality;
      if (accept(
        due,
        tick: tick,
        legality: masks,
        validTargets: validTargets,
      )) {
        return due;
      }
    }
    final last = _last;
    if (!paused &&
        last != null &&
        _pinsForHold(last) &&
        (last.target == null || validTargets.contains(last.target)) &&
        tick >= _lastAcceptedTick &&
        tick - _lastAcceptedTick <= maxHoldTicks &&
        (decoder.spec.branches.isEmpty || legality != null) &&
        decoder.decode(last.policyAction!, legality: legality) != null) {
      currentAction = decoder.decode(last.policyAction!, legality: legality)!;
      return BrainDecision._(
        identity,
        last.observationTick,
        tick,
        null,
        BehaviorStatus.succeeded,
        [],
        decoder.spec.hash,
        applyTick: tick,
        policyAction: last.policyAction,
        gameEpoch: gameEpoch,
        controlEpoch: controlEpoch,
        isHeld: true,
      );
    }
    currentAction = decoder.fallback;
    return BrainDecision._(
      identity,
      tick,
      tick,
      null,
      BehaviorStatus.failed,
      [],
      decoder.spec.hash,
      policyAction: currentAction.action,
      applyTick: tick,
      gameEpoch: gameEpoch,
      controlEpoch: controlEpoch,
      isFallback: true,
    );
  }

  bool _pinsForHold(BrainDecision d) =>
      d.isApplicable(entities, identity) &&
      d.gameEpoch == gameEpoch &&
      d.controlEpoch == controlEpoch &&
      d.stateEpoch == state.epoch;
  void synchronize({
    required int gameEpoch,
    required int controlEpoch,
    required bool paused,
    bool preserveCommittedState = false,
  }) {
    if (gameEpoch < 0 || controlEpoch < 0) {
      throw ArgumentError('Invalid ownership epoch.');
    }
    if (this.gameEpoch != gameEpoch ||
        this.controlEpoch != controlEpoch ||
        this.paused != paused) {
      invalidatePending(
        preserveState:
            preserveCommittedState ||
            this.gameEpoch == gameEpoch && this.controlEpoch == controlEpoch,
      );
    }
    _gameEpoch = gameEpoch;
    _controlEpoch = controlEpoch;
    _paused = paused;
  }

  void invalidatePending({bool preserveState = false}) {
    _staged = null;
    _last = null;
    _lastAcceptedTick = -1;
    if (preserveState) {
      state._invalidateEpoch();
    } else {
      state.reset();
    }
    currentAction = decoder.fallback;
  }

  void reset(BrainIdentity next) {
    if (next.modelHash != state.model.sha256) {
      throw ArgumentError('Replace the brain for another model.');
    }
    _identity = next;
    invalidatePending();
  }
}

List<List<bool>> _policyLegality(List<List<bool>> masks, ActionSpec spec) {
  if (masks.length != spec.branches.length) {
    throw ArgumentError('Legality branch count mismatch.');
  }
  return List.unmodifiable(
    List.generate(masks.length, (i) {
      if (masks[i].length != spec.branches[i].choices.length) {
        throw ArgumentError('Legality choice count mismatch.');
      }
      return List<bool>.unmodifiable(masks[i]);
    }),
  );
}
