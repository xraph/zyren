part of '../../zyren_game_ai.dart';

/// CPU scripted baseline using the shared bounded G6 behavior runner.
final class ScriptedBrain implements GameBrain {
  BrainIdentity _identity;
  BrainIdentity get identity => _identity;
  final GameEntityTable _entities;
  final BeliefStore memory;
  final GoalSelector selector;
  final GameSkillRegistry skills;
  final bool driver;
  final ActionSpec actionSpec;
  final double obstacleStopDistance;
  final String forwardRaySensorId;
  final int stepBudget, actionCapacity, maxObservationAgeTicks;
  final void Function(SkillCancellation)? onCancel;
  late final BrainSkillService _service;
  GameRuleRunner? _runner;
  GameGoal? _goal;
  ObservationFrame? _observation;
  int _lastDecisionTick = -1, _lastObservedTick = -1, _epoch = 0;
  bool _closed = false;
  ScriptedBrain({
    required BrainIdentity identity,
    required GameEntityTable entities,
    MemoryProfile? memoryProfile,
    GoalSelector? selector,
    GameSkillRegistry? skills,
    this.driver = false,
    ActionSpec? actionSpec,
    this.obstacleStopDistance = 3,
    this.forwardRaySensorId = 'rays',
    this.maxObservationAgeTicks = 1,
    this.stepBudget = 64,
    this.actionCapacity = 16,
    this.onCancel,
  }) : _identity = identity,
       _entities = entities,
       actionSpec = actionSpec ?? (driver ? driverActions : characterActions),
       memory = BeliefStore(identity: identity, profile: memoryProfile),
       selector = selector ?? UtilityGoalSelector(),
       skills = skills ?? GameSkillRegistry.defaults() {
    _bounded(
      maxObservationAgeTicks,
      3600,
      'maxObservationAgeTicks',
      zero: true,
    );
    _bounded(stepBudget, 4096, 'stepBudget');
    _bounded(actionCapacity, 256, 'actionCapacity');
    _name(forwardRaySensorId);
    if (!entities.isAlive(identity.entity) ||
        !obstacleStopDistance.isFinite ||
        obstacleStopDistance <= 0 ||
        obstacleStopDistance > 100000) {
      throw ArgumentError(
        'Brain requires a live actor and valid driver threshold.',
      );
    }
    _service = BrainSkillService(driver);
  }
  static ActionSpec get characterActions => ActionSpec(
    id: 'character-script',
    continuous: [ObservationField('moveX'), ObservationField('moveZ')],
    fallbackContinuous: [0, 0],
  );
  static ActionSpec get driverActions => ActionSpec(
    id: 'driver-script',
    continuous: [
      ObservationField('throttle', min: 0, max: 1),
      ObservationField('brake', min: 0, max: 1),
      ObservationField('steering'),
    ],
    fallbackContinuous: [0, 1, 0],
  );

  @override
  void observe(ObservationFrame frame) {
    if (_closed) throw StateError('Brain is closed.');
    if (!_entities.isAlive(identity.entity) ||
        frame.tick < _lastObservedTick ||
        frame.episodeId != identity.episodeId ||
        frame.entity != identity.entity) {
      throw ArgumentError('Stale or foreign observation.');
    }
    memory.observeFrame(frame);
    _observation = frame;
    _lastObservedTick = frame.tick;
  }

  @override
  BrainDecision decide(BrainContext context) {
    if (_closed) throw StateError('Brain is closed.');
    if (context.actionSpec.hash != actionSpec.hash ||
        context.identity != identity ||
        context.tick <= _lastDecisionTick ||
        context.tick < _lastObservedTick) {
      throw ArgumentError('Stale brain identity or decision tick.');
    }
    _lastDecisionTick = context.tick;
    final beliefs = memory.atTick(context.tick);
    final allowed = context.validTargets.where(_entities.isAlive).toSet();
    final goals = context.goals.isNotEmpty
        ? context.goals
        : _baseline(beliefs, context.tick, allowed);
    final permitted = BrainContext(
      identity: identity,
      tick: context.tick,
      observation: _observation,
      beliefs: beliefs,
      goals: goals,
      validTargets: allowed,
      actionSpec: context.actionSpec,
      utilityInputs: context.utilityInputs,
    );
    if (!_entities.isAlive(identity.entity)) {
      _cancel(SkillCancelReason.invalidTarget);
      return BrainDecision._(
        identity,
        _observation?.tick ?? context.tick,
        context.tick,
        null,
        BehaviorStatus.failed,
        [],
        context.actionSpec.hash,
      );
    }
    final next = selector.choose(permitted);
    if (next?.id != _goal?.id ||
        next?.skill != _goal?.skill ||
        next?.target != _goal?.target) {
      _cancel(
        _goal?.target != null && !_entities.isAlive(_goal!.target!)
            ? SkillCancelReason.invalidTarget
            : SkillCancelReason.goalChanged,
      );
      _goal = next;
      if (next != null) {
        _runner = skills
            .program(next.skill)
            .runner(
              actor: identity.entity,
              epoch: _epoch,
              services: {'game.ai.context': _service},
              stepBudget: stepBudget,
              queueCapacity: actionCapacity,
            );
      }
    }
    final runner = _runner;
    if (runner == null || next == null) {
      return BrainDecision._(
        identity,
        _observation?.tick ?? context.tick,
        context.tick,
        null,
        BehaviorStatus.failed,
        [],
        context.actionSpec.hash,
      );
    }
    _service._context = BrainContext(
      identity: identity,
      tick: context.tick,
      observation: _observation,
      beliefs: beliefs,
      goals: [next],
      validTargets: allowed,
      actionSpec: context.actionSpec,
      utilityInputs: context.utilityInputs,
    );
    final status = runner.step(
      tick: context.tick,
      epoch: _epoch,
      entities: _entities,
    );
    return BrainDecision._(
      identity,
      _observation?.tick ?? context.tick,
      context.tick,
      next,
      status,
      runner.drainCommands(),
      context.actionSpec.hash,
    );
  }

  List<GameGoal> _baseline(
    List<AgedBelief> beliefs,
    int tick,
    Set<GameEntityHandle> allowed,
  ) {
    if (driver) {
      final ray = _observation?.readings
          .where((r) => r.sensorId == forwardRaySensorId)
          .firstOrNull;
      final known =
          _observation != null &&
          tick - _observation!.tick <= maxObservationAgeTicks &&
          ray != null &&
          ray.values.isNotEmpty &&
          ray.validity.first == 1;
      final blocked = !known || ray.values.first <= obstacleStopDistance;
      return [
        GameGoal(
          id: blocked ? 'brake' : 'route',
          skill: blocked ? 'idle' : 'follow-route',
          route: blocked ? const [] : [const Vec3(0, 0, -1)],
        ),
      ];
    }
    final candidates =
        beliefs
            .where(
              (b) =>
                  b.confidence > 0 &&
                  b.positionFrame == identity.entity &&
                  (b.target == null || allowed.contains(b.target)),
            )
            .toList()
          ..sort((a, b) {
            final c = b.confidence.compareTo(a.confidence);
            return c == 0 ? a.key.compareTo(b.key) : c;
          });
    final belief = candidates.firstOrNull;
    return [
      if (belief != null)
        GameGoal(
          id: 'investigate',
          skill: 'investigate',
          target: belief.target,
          beliefKey: belief.key,
          priority: 10,
          utility: belief.confidence,
        )
      else
        GameGoal(id: 'idle', skill: 'idle'),
    ];
  }

  void _cancel(SkillCancelReason reason) {
    final runner = _runner, goal = _goal;
    _runner = null;
    _goal = null;
    try {
      runner?.close();
    } finally {
      if (goal != null) {
        onCancel?.call(
          SkillCancellation(
            goal.skill,
            goal.id,
            identity,
            math.max(0, _lastDecisionTick),
            reason,
          ),
        );
      }
    }
  }

  @override
  void reset(BrainReset reset) {
    if (_closed) throw StateError('Brain is closed.');
    // Validate the replacement envelope before cancelling the current skill.
    BeliefStore(identity: reset.identity, profile: memory.profile);
    try {
      _cancel(SkillCancelReason.reset);
    } finally {
      _identity = reset.identity;
      _epoch++;
      memory.reset(reset);
      selector.reset();
      _observation = null;
      _lastDecisionTick = -1;
      _lastObservedTick = -1;
      _service._context = null;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      _cancel(SkillCancelReason.closed);
    } finally {
      memory.reset(BrainReset(identity, BrainResetReason.despawned));
      _observation = null;
      _service._context = null;
    }
  }
}
