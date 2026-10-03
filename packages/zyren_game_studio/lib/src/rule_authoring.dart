part of '../levels.dart';

/// Each edit returns one complete graph; invalid intermediate graphs never save.
final class GameRuleAuthoring {
  final GameAuthoring authoring;
  final GameRuleLibrary library;
  final String? state;
  GameRuleAuthoring(this.authoring, this.library, {this.state});
  StudioDocument replace(
    StudioDocument document,
    String nodeId,
    GameRuleDefinition definition,
  ) {
    definition.graph.compile(library.actions, library.predicates);
    if (state != null) {
      final machines = GameStateMachineAuthoring(authoring, library);
      final machine = machines.read(document, nodeId);
      if (!machine.states.containsKey(state)) {
        throw ArgumentError('Unknown state.');
      }
      return machines.replace(
        document,
        nodeId,
        GameStateMachineDefinition(
          initial: machine.initial,
          transitions: machine.transitions,
          states: {...machine.states, state!: definition},
        ),
      );
    }
    final entity = authoring.entityFor(document, nodeId);
    if (entity?.components.any((c) => c.type == 'game.rules') ?? false) {
      return authoring.setFields(
        document,
        nodeId: nodeId,
        component: 'game.rules',
        fields: definition.toJson(),
      );
    }
    return authoring.addComponent(
      document,
      nodeId,
      GameComponentRecord('game.rules', 1, definition.toJson()),
    );
  }

  GameRuleDefinition read(StudioDocument document, String nodeId) =>
      state != null
      ? GameStateMachineAuthoring(
          authoring,
          library,
        ).read(document, nodeId).states[state]!
      : GameRuleDefinition.fromJson(
          authoring
              .entityFor(document, nodeId)!
              .components
              .singleWhere((c) => c.type == 'game.rules')
              .data,
        );
  StudioDocument invert(StudioDocument document, String nodeId, String ruleId) {
    final current = read(document, nodeId);
    final node = current.graph.nodes.singleWhere((n) => n.id == ruleId);
    var suffix = 1;
    while (current.graph.nodes.any((n) => n.id == 'invert-$suffix')) {
      suffix++;
    }
    final remove = node.kind == GameRuleKind.inverter;
    final replacement = remove ? node.children.single : 'invert-$suffix';
    return replace(
      document,
      nodeId,
      GameRuleDefinition(
        repeat: current.repeat,
        graph: GameRuleGraph(
          root: current.graph.root == ruleId ? replacement : current.graph.root,
          nodes: [
            for (final old in current.graph.nodes)
              if (!(remove && old.id == ruleId))
                GameRuleNode(
                  id: old.id,
                  kind: old.kind,
                  operation: old.operation,
                  arguments: old.arguments,
                  children: old.children
                      .map((id) => id == ruleId ? replacement : id)
                      .toList(),
                ),
            if (!remove)
              GameRuleNode(
                id: replacement,
                kind: GameRuleKind.inverter,
                children: [ruleId],
              ),
          ],
        ),
      ),
    );
  }

  StudioDocument moveChild(
    StudioDocument document,
    String nodeId,
    String parentId,
    int from,
    int to,
  ) {
    final current = read(document, nodeId);
    final parent = current.graph.nodes.singleWhere((n) => n.id == parentId);
    final children = [...parent.children];
    if (from < 0 ||
        to < 0 ||
        from >= children.length ||
        to >= children.length) {
      throw RangeError('Child index is outside the graph.');
    }
    children.insert(to, children.removeAt(from));
    return replaceNode(
      document,
      nodeId,
      GameRuleNode(
        id: parent.id,
        kind: parent.kind,
        operation: parent.operation,
        arguments: parent.arguments,
        children: children,
      ),
    );
  }

  StudioDocument appendChild(
    StudioDocument document,
    String nodeId,
    String parentId,
    GameRuleNode child,
  ) {
    final current = read(document, nodeId);
    final parent = current.graph.nodes.singleWhere((n) => n.id == parentId);
    if (parent.kind != GameRuleKind.sequence &&
        parent.kind != GameRuleKind.selector) {
      throw ArgumentError('Choose a sequence or selector parent.');
    }
    return replace(
      document,
      nodeId,
      GameRuleDefinition(
        repeat: current.repeat,
        graph: GameRuleGraph(
          root: current.graph.root,
          nodes: [
            for (final node in current.graph.nodes)
              node.id != parentId
                  ? node
                  : GameRuleNode(
                      id: parent.id,
                      kind: parent.kind,
                      children: [...parent.children, child.id],
                    ),
            child,
          ],
        ),
      ),
    );
  }

  StudioDocument replaceNode(
    StudioDocument document,
    String nodeId,
    GameRuleNode node,
  ) {
    final current = read(document, nodeId);
    if (!current.graph.nodes.any((n) => n.id == node.id)) {
      throw ArgumentError('Unknown rule node.');
    }
    return replace(
      document,
      nodeId,
      GameRuleDefinition(
        repeat: current.repeat,
        graph: GameRuleGraph(
          root: current.graph.root,
          nodes: [
            for (final old in current.graph.nodes)
              old.id == node.id ? node : old,
          ],
        ),
      ),
    );
  }

  StudioDocument removeSubtree(
    StudioDocument document,
    String nodeId,
    String ruleId,
  ) {
    final current = read(document, nodeId);
    final nodes = {for (final node in current.graph.nodes) node.id: node};
    if (!nodes.containsKey(ruleId)) throw ArgumentError('Unknown rule node.');
    if (ruleId == current.graph.root) {
      throw ArgumentError('Replace the root graph instead.');
    }
    final removed = <String>{};
    void visit(String id) {
      if (!removed.add(id)) return;
      nodes[id]!.children.forEach(visit);
    }

    visit(ruleId);
    return replace(
      document,
      nodeId,
      GameRuleDefinition(
        repeat: current.repeat,
        graph: GameRuleGraph(
          root: current.graph.root,
          nodes: [
            for (final node in nodes.values)
              if (!removed.contains(node.id))
                GameRuleNode(
                  id: node.id,
                  kind: node.kind,
                  operation: node.operation,
                  arguments: node.arguments,
                  children: node.children
                      .where((id) => !removed.contains(id))
                      .toList(),
                ),
          ],
        ),
      ),
    );
  }
}
