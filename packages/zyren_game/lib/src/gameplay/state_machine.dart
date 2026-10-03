part of '../../zyren_game.dart';

final class GameStateTransition {
  final String from, to, predicate;
  final Map<String, Object?> arguments;
  GameStateTransition({
    required String from,
    required String to,
    required String predicate,
    Map<String, Object?> arguments = const {},
  }) : from = _id(from),
       to = _id(to),
       predicate = _id(predicate),
       arguments = _json(arguments);
}

/// A guard may transition once per tick. Exiting cancels the old state's actions.
final class GameStateMachine {
  final Map<String, GameRuleProgram> states;
  final List<GameStateTransition> transitions;
  final GameEntityHandle actor;
  final int epoch, stepBudget, queueCapacity;
  final Map<String, Object> _services;
  final Map<String, _RuleOperation> _predicates;
  String _state;
  late GameRuleRunner _runner;
  final List<Map<String, Object?>> _events = [];
  final List<GameRuleCommand> _commands = [];
  int _lastTick = -1;
  bool _closed = false;
  String get state => _state;
  GameStateMachine({
    required Map<String, GameRuleProgram> states,
    required List<GameStateTransition> transitions,
    required String initial,
    required this.actor,
    required this.epoch,
    required GamePredicateRegistry predicates,
    Map<String, Object> services = const {},
    this.stepBudget = 64,
    this.queueCapacity = 256,
  }) : states = Map.unmodifiable(states),
       transitions = List.unmodifiable(transitions),
       _state = initial,
       _services = Map.unmodifiable(services),
       _predicates = Map.unmodifiable(predicates._operations) {
    if (states.isEmpty ||
        states.length > 64 ||
        !states.containsKey(initial) ||
        transitions.length > 256) {
      throw const FormatException(
        'Invalid state machine bounds or initial state.',
      );
    }
    states.keys.forEach(_id);
    for (final transition in transitions) {
      final predicate = _predicates[transition.predicate];
      if (!states.containsKey(transition.from) ||
          !states.containsKey(transition.to) ||
          predicate == null) {
        throw const FormatException('Invalid state transition reference.');
      }
      predicate.validate(transition.arguments);
      if (!services.keys.toSet().containsAll(predicate.services)) {
        throw StateError('Missing state guard service.');
      }
    }
    // Validate every state's requirements before the first transition can run.
    for (final program in states.values) {
      _newRunner(program).close();
    }
    _runner = _newRunner(states[initial]!);
  }
  GameRuleRunner _newRunner(GameRuleProgram program) => program.runner(
    actor: actor,
    epoch: epoch,
    services: _services,
    stepBudget: stepBudget,
    queueCapacity: queueCapacity,
  );
  List<Map<String, Object?>> drainEvents() {
    final result = List<Map<String, Object?>>.unmodifiable(_events);
    _events.clear();
    return result;
  }

  List<GameRuleCommand> drainCommands() {
    final result = List<GameRuleCommand>.unmodifiable(_commands);
    _commands.clear();
    return result;
  }

  BehaviorStatus step({
    required int tick,
    required int epoch,
    required GameEntityTable entities,
  }) {
    if (_closed) return BehaviorStatus.failed;
    if (epoch != this.epoch || !entities.isAlive(actor)) {
      close();
      return BehaviorStatus.failed;
    }
    if (tick < 0 || tick <= _lastTick) {
      throw StateError('State machine ticks must increase.');
    }
    _lastTick = tick;
    try {
      for (final transition in transitions.where((t) => t.from == _state)) {
        final operation = _predicates[transition.predicate]!;
        final context = BehaviorContext._(
          _runner,
          tick,
          operation.services,
          readOnly: true,
        );
        bool selected;
        try {
          selected = operation.predicate!(context, transition.arguments);
        } finally {
          context._open = false;
        }
        if (selected) {
          _runner.close();
          _state = transition.to;
          _runner = _newRunner(states[_state]!);
          break;
        }
      }
      final result = _runner.step(tick: tick, epoch: epoch, entities: entities);
      final events = _runner.drainEvents();
      final commands = _runner.drainCommands();
      if (_events.length + events.length > queueCapacity ||
          _commands.length + commands.length > queueCapacity) {
        throw StateError('State machine output backpressure.');
      }
      _events.addAll(events);
      _commands.addAll(commands);
      return result;
    } catch (error, stack) {
      try {
        close();
      } catch (_) {
        /* Preserve the initiating rule failure. */
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _events.clear();
    _commands.clear();
    _runner.close();
  }
}
