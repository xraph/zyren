part of '../../zyren_game_ai.dart';

/// Goal selection routes to explicitly registered scripted or learned skills.
final class HybridBrain implements GameBrain {
  BrainIdentity _identity;
  final GoalSelector selector;
  final Map<String, GameBrain> _skills;
  final Map<String, ActionSpec> _schemas;
  ObservationFrame? _frame;
  String? _active;
  bool _closed = false;
  String? get activeSkill => _active;
  List<String> get skillIds => List.unmodifiable(_skills.keys);
  HybridBrain({
    required BrainIdentity identity,
    required this.selector,
    required Map<String, GameBrain> skills,
    required Map<String, ActionSpec> actionSpecs,
  }) : _identity = identity,
       _skills = _hybridSkills(skills),
       _schemas = _hybridSchemas(actionSpecs) {
    if (_schemas.length != _skills.length ||
        !_skills.keys.every(_schemas.containsKey)) {
      throw ArgumentError(
        'Each hybrid skill needs its explicit action schema.',
      );
    }
  }
  @override
  void observe(ObservationFrame frame) {
    if (_closed) throw StateError('Hybrid brain is closed.');
    if (frame.entity != _identity.entity ||
        frame.episodeId != _identity.episodeId ||
        _frame != null && frame.tick < _frame!.tick) {
      throw ArgumentError('Foreign hybrid observation.');
    }
    _frame = frame;
  }

  @override
  BrainDecision decide(BrainContext context) {
    if (_closed) throw StateError('Hybrid brain is closed.');
    if (context.identity != _identity) {
      throw ArgumentError('Foreign hybrid context.');
    }
    final goal = selector.choose(context);
    final next = goal?.skill;
    if (next != null && !_skills.containsKey(next)) {
      throw StateError('Unregistered hybrid skill.');
    }
    final schema = _schemas[next];
    // Masks belong to a particular discrete schema. Command-based skills have
    // no branches; another discrete schema needs its own caller-supplied mask.
    if (schema != null &&
        schema.branches.isNotEmpty &&
        context.legality != null &&
        schema.hash != context.actionSpec.hash) {
      throw ArgumentError('Hybrid action mask belongs to another schema.');
    }
    if (next != _active) {
      final previous = _skills[_active];
      previous?.reset(BrainReset(_identity, BrainResetReason.manual));
      _active = next;
    }
    final skill = _skills[next];
    if (skill == null || goal == null) {
      return BrainDecision._(
        _identity,
        context.tick,
        context.tick,
        null,
        BehaviorStatus.failed,
        [],
        context.actionSpec.hash,
        isFallback: true,
      );
    }
    if (_frame != null) skill.observe(_frame!);
    return skill.decide(
      BrainContext(
        identity: _identity,
        tick: context.tick,
        gameEpoch: context.gameEpoch,
        controlEpoch: context.controlEpoch,
        observation: _frame,
        beliefs: context.beliefs,
        goals: [goal],
        validTargets: context.validTargets,
        actionSpec: schema!,
        utilityInputs: context.utilityInputs,
        legality: schema.branches.isEmpty ? null : context.legality,
      ),
    );
  }

  @override
  void reset(BrainReset reset) {
    if (_closed) throw StateError('Hybrid brain is closed.');
    for (final skill in _skills.values) {
      skill.reset(reset);
    }
    _identity = reset.identity;
    selector.reset();
    _active = null;
    _frame = null;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _active = null;
    _frame = null;
    await Future.wait(_skills.values.map((skill) => skill.close()));
  }
}

Map<String, GameBrain> _hybridSkills(Map<String, GameBrain> source) {
  if (source.isEmpty ||
      source.length > 32 ||
      source.values.toSet().length != source.length) {
    throw ArgumentError('Hybrid skills need1..32 independent brains.');
  }
  for (final key in source.keys) {
    _name(key);
  }
  return Map.unmodifiable(source);
}

Map<String, ActionSpec> _hybridSchemas(Map<String, ActionSpec> source) {
  if (source.length > 32) throw ArgumentError('Hybrid schema limit exceeded.');
  return Map.unmodifiable(source);
}
