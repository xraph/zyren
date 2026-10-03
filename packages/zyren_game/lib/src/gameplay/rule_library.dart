part of '../../zyren_game.dart';

/// Read-only facts use the bound actor, never an arbitrary entity from graph text.
abstract interface class GameRuleFacts {
  bool hasItem(GameEntityHandle actor, String item, int count);
  bool objectiveComplete(GameEntityHandle actor, String objective);
  bool interactionApplied(GameEntityHandle actor, String interaction);
}

abstract interface class GameRuleSpatialFacts {
  bool within(GameEntityHandle actor, String target, double distance);
  bool controlling(GameEntityHandle actor, String target);
}

/// The host dispatches these data commands through gameplay and reach checks.
final class GameRuleLibrary {
  final GameActionRegistry actions = GameActionRegistry();
  final GamePredicateRegistry predicates = GamePredicateRegistry();
  GameRuleLibrary() {
    const text = GamePortType.string, integer = GamePortType.integer;
    final operations = <String, Map<String, GamePortType>>{
      'game.interact': {'interaction': text},
      'game.use-ability': {'ability': text},
      'game.credit-objective': {'objective': text, 'count': integer},
      'game.transfer-item': {'target': text, 'item': text, 'count': integer},
      'game.collect-item': {'source': text, 'item': text, 'count': integer},
      'game.possess': {'target': text},
      'game.set-active': {'target': text, 'active': GamePortType.boolean},
      'game.consume-interaction': {'interaction': text},
    };
    for (final entry in operations.entries) {
      actions.register(
        entry.key,
        ports: entry.value,
        factory: (args) => _GameQueuedRuleAction(entry.key, args),
      );
    }
    predicates.register(
      'game.has-item',
      ports: {'item': text, 'count': integer},
      services: {'game.facts'},
      evaluate: (c, a) => c
          .service<GameRuleFacts>('game.facts')
          .hasItem(c.actor, a['item'] as String, a['count'] as int),
    );
    predicates.register(
      'game.objective-complete',
      ports: {'objective': text},
      services: {'game.facts'},
      evaluate: (c, a) => c
          .service<GameRuleFacts>('game.facts')
          .objectiveComplete(c.actor, a['objective'] as String),
    );
    predicates.register(
      'game.interaction-applied',
      ports: {'interaction': text},
      services: {'game.facts'},
      evaluate: (c, a) => c
          .service<GameRuleFacts>('game.facts')
          .interactionApplied(c.actor, a['interaction'] as String),
    );
    predicates.register(
      'game.within',
      ports: {'target': text, 'distance': GamePortType.number},
      services: {'game.spatial'},
      evaluate: (c, a) => c
          .service<GameRuleSpatialFacts>('game.spatial')
          .within(
            c.actor,
            a['target'] as String,
            (a['distance'] as num).toDouble(),
          ),
    );
    predicates.register(
      'game.is-controlling',
      ports: {'target': text},
      services: {'game.spatial'},
      evaluate: (c, a) => c
          .service<GameRuleSpatialFacts>('game.spatial')
          .controlling(c.actor, a['target'] as String),
    );
  }
}

final class _GameQueuedRuleAction extends GameRuleAction {
  final String operation;
  final Map<String, Object?> arguments;
  _GameQueuedRuleAction(this.operation, this.arguments);
  @override
  BehaviorStatus tick(BehaviorContext context) {
    context.enqueue(operation, arguments);
    return BehaviorStatus.succeeded;
  }
}

final class GameRuleDefinition {
  final GameRuleGraph graph;
  final bool repeat;
  GameRuleDefinition({required this.graph, this.repeat = true});
  Map<String, Object?> toJson() => {'graph': graph.toJson(), 'repeat': repeat};
  factory GameRuleDefinition.fromJson(Map<String, Object?> data) =>
      GameRuleDefinition(
        graph: GameRuleGraph.fromJson(_map(data['graph'])),
        repeat: data['repeat'] as bool,
      );
}

/// Registry validation and runtime construction compile against the same code.
final class GameRuleComponentCodec
    extends GameComponentCodec<GameRuleDefinition> {
  final GameActionRegistry actions;
  final GamePredicateRegistry predicates;
  GameRuleComponentCodec(this.actions, this.predicates);
  @override
  String get type => 'game.rules';
  @override
  int get version => 1;
  @override
  void validate(Map<String, Object?> data) {
    GameRuleDefinition.fromJson(data).graph.compile(actions, predicates);
  }

  @override
  GameRuleDefinition factory(Map<String, Object?> data) {
    validate(data);
    return GameRuleDefinition.fromJson(data);
  }

  @override
  Iterable<GameLocalReference> localReferences(
    Map<String, Object?> data,
  ) sync* {
    final graph = GameRuleDefinition.fromJson(data).graph;
    for (var i = 0; i < graph.nodes.length; i++) {
      final node = graph.nodes[i];
      if (node.operation == 'game.transfer-item' ||
          node.operation == 'game.collect-item' ||
          node.operation == 'game.possess' ||
          node.operation == 'game.set-active' ||
          node.operation == 'game.within' ||
          node.operation == 'game.is-controlling') {
        final field = node.operation == 'game.collect-item'
            ? 'source'
            : 'target';
        yield GameLocalReference([
          'graph',
          'nodes',
          i,
          'arguments',
          field,
        ], _string(node.arguments[field]));
      }
    }
  }

  @override
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data) =>
      throw FormatException('Unsupported game rules version $fromVersion.');
}
