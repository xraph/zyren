part of '../../zyren_game.dart';

final class GameStateMachineDefinition {
  final String initial;
  final Map<String, GameRuleDefinition> states;
  final List<GameStateTransition> transitions;
  GameStateMachineDefinition({
    required this.initial,
    required Map<String, GameRuleDefinition> states,
    required List<GameStateTransition> transitions,
  }) : states = Map.unmodifiable(states),
       transitions = List.unmodifiable(transitions) {
    if (states.isEmpty ||
        states.length > 64 ||
        transitions.length > 256 ||
        !states.containsKey(initial)) {
      throw const FormatException(
        'Invalid state machine bounds or initial state.',
      );
    }
    states.keys.forEach(_id);
    if (transitions.any(
      (t) => !states.containsKey(t.from) || !states.containsKey(t.to),
    )) {
      throw const FormatException('Transition state is missing.');
    }
  }
  void validate(GameActionRegistry actions, GamePredicateRegistry predicates) {
    for (final state in states.values) {
      state.graph.compile(actions, predicates);
    }
    for (final transition in transitions) {
      final predicate = predicates._operations[transition.predicate];
      if (predicate == null) {
        throw const FormatException('Transition predicate is unregistered.');
      }
      predicate.validate(transition.arguments);
    }
  }

  GameStateMachine instantiate({
    required GameEntityHandle actor,
    required int epoch,
    required GameActionRegistry actions,
    required GamePredicateRegistry predicates,
    Map<String, Object> services = const {},
  }) {
    validate(actions, predicates);
    return GameStateMachine(
      states: {
        for (final state in states.entries)
          state.key: state.value.graph.compile(actions, predicates),
      },
      transitions: transitions,
      initial: initial,
      actor: actor,
      epoch: epoch,
      predicates: predicates,
      services: services,
      repeatStates: {
        for (final state in states.entries)
          if (state.value.repeat) state.key,
      },
    );
  }

  Map<String, Object?> toJson() => {
    'initial': initial,
    'states': {
      for (final state in states.entries) state.key: state.value.toJson(),
    },
    'transitions': [
      for (final t in transitions)
        {
          'from': t.from,
          'to': t.to,
          'predicate': t.predicate,
          'arguments': t.arguments,
        },
    ],
  };
  factory GameStateMachineDefinition.fromJson(Map<String, Object?> data) =>
      GameStateMachineDefinition(
        initial: _string(data['initial']),
        states: _map(
          data['states'],
        ).map((k, v) => MapEntry(k, GameRuleDefinition.fromJson(_map(v)))),
        transitions: _list(data['transitions']).map((v) {
          final t = _map(v);
          return GameStateTransition(
            from: _string(t['from']),
            to: _string(t['to']),
            predicate: _string(t['predicate']),
            arguments: _map(t['arguments']),
          );
        }).toList(),
      );
}

final class GameStateMachineComponentCodec
    extends GameComponentCodec<GameStateMachineDefinition> {
  final GameActionRegistry actions;
  final GamePredicateRegistry predicates;
  GameStateMachineComponentCodec(this.actions, this.predicates);
  @override
  String get type => 'game.state-machine';
  @override
  int get version => 1;
  @override
  void validate(Map<String, Object?> data) =>
      GameStateMachineDefinition.fromJson(data).validate(actions, predicates);
  @override
  GameStateMachineDefinition factory(Map<String, Object?> data) {
    validate(data);
    return GameStateMachineDefinition.fromJson(data);
  }

  @override
  Iterable<GameLocalReference> localReferences(
    Map<String, Object?> data,
  ) sync* {
    final definition = GameStateMachineDefinition.fromJson(data);
    final codec = GameRuleComponentCodec(actions, predicates);
    for (final state in definition.states.entries) {
      for (final reference in codec.localReferences(state.value.toJson())) {
        yield GameLocalReference([
          'states',
          state.key,
          ...reference.path,
        ], reference.targetId);
      }
    }
  }

  @override
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data) =>
      throw FormatException(
        'Unsupported game state machine version $fromVersion.',
      );
}
