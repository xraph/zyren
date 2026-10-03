part of '../../levels.dart';

StudioDocument _addTemplateVehicle(
  GameAuthoring authoring,
  StudioDocument document,
) {
  var next = document.copyWith(
    nodes: [
      ...document.nodes,
      StudioNode(
        id: 'vehicle',
        label: 'Buggy',
        position: const Vec3(4, 1, 0),
        size: const Vec3(1.4, .7, 2),
        color: 0xe9a155,
      ),
    ],
  );
  next = GameLevelAuthoring(authoring).bindCollider(
    next,
    'vehicle',
    GameColliderDefinition(
      motion: GameBodyMotion.dynamic,
      halfExtents: const Vec3(.7, .35, 1),
      mass: 1200,
    ),
  );
  next = authoring.addComponent(
    next,
    'vehicle',
    authoring.descriptors['game.vehicle']!.create(),
  );
  next = authoring.addComponent(
    next,
    'vehicle',
    GameComponentRecord(
      'game.interaction',
      1,
      GameInteractionDefinition(
        id: 'enter-vehicle',
        target: 'vehicle',
        label: 'Drive vehicle',
      ).toJson(),
    ),
  );
  final rules = GameRuleDefinition.fromJson(
    authoring
        .entityFor(next, 'player')!
        .components
        .singleWhere((c) => c.type == 'game.rules')
        .data,
  );
  next = authoring.setFields(
    next,
    nodeId: 'player',
    component: 'game.rules',
    fields: GameRuleDefinition(
      graph: GameRuleGraph(
        root: rules.graph.root,
        nodes: [
          for (final node in rules.graph.nodes)
            node.id != rules.graph.root
                ? node
                : GameRuleNode.selector(node.id, [
                    ...node.children,
                    'enter-vehicle',
                  ]),
          GameRuleNode.sequence('enter-vehicle', [
            'vehicle-requested',
            'vehicle-possess',
            'vehicle-consume',
          ]),
          GameRuleNode.predicate(
            'vehicle-requested',
            'game.interaction-applied',
            arguments: {'interaction': 'enter-vehicle'},
          ),
          GameRuleNode.action(
            'vehicle-possess',
            'game.possess',
            arguments: {'target': 'vehicle'},
          ),
          GameRuleNode.action(
            'vehicle-consume',
            'game.consume-interaction',
            arguments: {'interaction': 'enter-vehicle'},
          ),
        ],
      ),
    ).toJson(),
  );
  return next;
}
