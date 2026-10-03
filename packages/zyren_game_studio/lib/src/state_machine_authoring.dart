part of '../levels.dart';

final class GameStateMachineAuthoring {
  final GameAuthoring authoring;
  final GameRuleLibrary library;
  GameStateMachineAuthoring(this.authoring, this.library);

  GameStateMachineDefinition read(StudioDocument document, String nodeId) =>
      GameStateMachineDefinition.fromJson(
        authoring
            .entityFor(document, nodeId)!
            .components
            .singleWhere((c) => c.type == 'game.state-machine')
            .data,
      );

  StudioDocument replace(
    StudioDocument document,
    String nodeId,
    GameStateMachineDefinition definition,
  ) {
    definition.validate(library.actions, library.predicates);
    final exists =
        authoring
            .entityFor(document, nodeId)
            ?.components
            .any((c) => c.type == 'game.state-machine') ??
        false;
    return exists
        ? authoring.setFields(
            document,
            nodeId: nodeId,
            component: 'game.state-machine',
            fields: definition.toJson(),
          )
        : authoring.addComponent(
            document,
            nodeId,
            GameComponentRecord('game.state-machine', 1, definition.toJson()),
          );
  }

  StudioDocument addState(
    StudioDocument document,
    String nodeId,
    String state,
  ) {
    final current = read(document, nodeId);
    if (current.states.containsKey(state)) {
      throw ArgumentError('State already exists.');
    }
    return replace(
      document,
      nodeId,
      GameStateMachineDefinition(
        initial: current.initial,
        transitions: current.transitions,
        states: {
          ...current.states,
          state: GameRuleDefinition(
            graph: GameRuleGraph(
              root: 'root',
              nodes: [GameRuleNode.sequence('root', [])],
            ),
          ),
        },
      ),
    );
  }

  /// Removing a state also removes its transitions in the same history edit.
  StudioDocument removeState(
    StudioDocument document,
    String nodeId,
    String state,
  ) {
    final current = read(document, nodeId);
    if (!current.states.containsKey(state) || state == current.initial) {
      throw ArgumentError('Choose a non-initial state.');
    }
    return replace(
      document,
      nodeId,
      GameStateMachineDefinition(
        initial: current.initial,
        states: {...current.states}..remove(state),
        transitions: current.transitions
            .where((t) => t.from != state && t.to != state)
            .toList(),
      ),
    );
  }
}
