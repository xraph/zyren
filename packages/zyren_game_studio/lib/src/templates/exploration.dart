part of '../../levels.dart';

final class GameTemplateResult {
  final StudioDocument document;
  final List<StudioAsset> assetRequirements;
  GameTemplateResult(
    this.document, {
    List<StudioAsset> assetRequirements = const [],
  }) : assetRequirements = List.unmodifiable(assetRequirements);
}

enum GameTemplateKind { exploration, vehiclePlayground }

final class GameTemplate {
  final GameTemplateKind kind;
  final GameAuthoring authoring;
  GameTemplate(this.kind, this.authoring);
  GameTemplateResult create({required String projectId, String? documentId}) {
    var document = authoring.initialize(
      StudioDocument(
        id: documentId ?? '$projectId-scene',
        title: kind == GameTemplateKind.exploration
            ? 'Exploration'
            : 'Vehicle playground',
        nodes: [
          StudioNode(
            id: 'ground',
            label: 'Ground',
            position: const Vec3(0, -.5, 0),
            size: const Vec3(30, 1, 30),
            color: 0x566c53,
          ),
          StudioNode(
            id: 'player',
            label: 'Player',
            position: const Vec3(0, 1.5, 0),
            size: const Vec3(.6, 1.8, .6),
            color: 0x54bde3,
          ),
          StudioNode(
            id: 'key',
            label: 'Key',
            position: const Vec3(0, .4, 2),
            size: const Vec3(.3, .3, .3),
            color: 0xf2cc5e,
          ),
          StudioNode(
            id: 'gate',
            label: 'Gate',
            position: const Vec3(0, 1.2, 6),
            size: const Vec3(3, 2.4, .3),
            color: 0x884d4d,
          ),
          StudioNode(
            id: 'spawn',
            label: 'Start',
            kind: StudioNodeKind.group,
            position: const Vec3(0, 1.5, 0),
          ),
          StudioNode(
            id: 'checkpoint',
            label: 'Checkpoint',
            kind: StudioNodeKind.group,
            position: const Vec3(0, 1, 9),
          ),
        ],
      ),
      projectId: projectId,
      levelId: 'main',
    );
    final level = GameLevelAuthoring(authoring);
    document = level.bindCollider(
      document,
      'ground',
      GameColliderDefinition(halfExtents: const Vec3(15, .5, 15)),
    );
    document = level.bindCollider(
      document,
      'player',
      GameColliderDefinition(
        shape: GameColliderShape.capsule,
        motion: GameBodyMotion.kinematic,
      ),
    );
    document = level.bindCollider(
      document,
      'gate',
      GameColliderDefinition(halfExtents: const Vec3(1.5, 1.2, .15)),
    );
    document = level.bindCollider(
      document,
      'key',
      GameColliderDefinition(
        halfExtents: const Vec3(.15, .15, .15),
        sensor: true,
      ),
    );
    for (final type in [
      'game.character',
      'game.input',
      'game.inventory',
      'game.abilities',
      'game.objectives',
    ]) {
      document = authoring.addComponent(
        document,
        'player',
        authoring.descriptors[type]!.create(),
      );
    }
    document = authoring.setFields(
      document,
      nodeId: 'player',
      component: 'game.objectives',
      fields: {
        'targets': {'key': 1, 'gate': 1, 'checkpoint': 1},
      },
    );
    document = authoring.addComponent(
      document,
      'player',
      GameComponentRecord('game.camera', 1, {
        ...authoring.descriptors['game.camera']!.create().data,
        'target': 'player',
      }),
    );
    document = authoring.addComponent(
      document,
      'key',
      GameComponentRecord(
        'game.inventory',
        1,
        Inventory(capacity: 1, items: {'key': 1}).toJson(),
      ),
    );
    for (final entry in {'key': 'pickup-key', 'gate': 'open-gate'}.entries) {
      document = authoring.addComponent(
        document,
        entry.key,
        GameComponentRecord(
          'game.interaction',
          1,
          GameInteractionDefinition(
            id: entry.value,
            target: entry.key,
            label: entry.key == 'key' ? 'Pick up key' : 'Open gate',
            requiredItems: entry.key == 'gate' ? {'key': 1} : {},
          ).toJson(),
        ),
      );
    }
    document = level.spawn(document, 'spawn', 'default');
    document = level.checkpoint(document, 'checkpoint', spawnEntity: 'spawn');
    document = authoring.addComponent(
      document,
      'player',
      GameComponentRecord(
        'game.rules',
        1,
        GameRuleDefinition(graph: _explorationRules()).toJson(),
      ),
    );
    if (kind == GameTemplateKind.vehiclePlayground) {
      document = _addTemplateVehicle(authoring, document);
    }
    final issues = authoring.validate(document).where((e) => e.blocksPlay);
    if (issues.isNotEmpty) throw GameAuthoringException(issues);
    return GameTemplateResult(document);
  }
}

GameRuleGraph _explorationRules() => GameRuleGraph(
  root: 'root',
  nodes: [
    GameRuleNode.selector('root', [
      'credit-key',
      'collect-key',
      'credit-gate',
      'credit-checkpoint',
    ]),
    GameRuleNode.sequence('credit-key', [
      'has-key',
      'key-unfinished',
      'hide-key',
      'key-credit',
    ]),
    GameRuleNode.predicate(
      'has-key',
      'game.has-item',
      arguments: {'item': 'key', 'count': 1},
    ),
    GameRuleNode(
      id: 'key-unfinished',
      kind: GameRuleKind.inverter,
      children: ['key-complete'],
    ),
    GameRuleNode.predicate(
      'key-complete',
      'game.objective-complete',
      arguments: {'objective': 'key'},
    ),
    GameRuleNode.action(
      'hide-key',
      'game.set-active',
      arguments: {'target': 'key', 'active': false},
    ),
    GameRuleNode.action(
      'key-credit',
      'game.credit-objective',
      arguments: {'objective': 'key', 'count': 1},
    ),
    GameRuleNode.sequence('collect-key', [
      'key-missing',
      'pickup-applied',
      'collect',
    ]),
    GameRuleNode(
      id: 'key-missing',
      kind: GameRuleKind.inverter,
      children: ['key-owned'],
    ),
    GameRuleNode.predicate(
      'key-owned',
      'game.has-item',
      arguments: {'item': 'key', 'count': 1},
    ),
    GameRuleNode.predicate(
      'pickup-applied',
      'game.interaction-applied',
      arguments: {'interaction': 'pickup-key'},
    ),
    GameRuleNode.action(
      'collect',
      'game.collect-item',
      arguments: {'source': 'key', 'item': 'key', 'count': 1},
    ),
    GameRuleNode.sequence('credit-gate', [
      'gate-open',
      'gate-unfinished',
      'hide-gate',
      'gate-credit',
    ]),
    GameRuleNode.predicate(
      'gate-open',
      'game.interaction-applied',
      arguments: {'interaction': 'open-gate'},
    ),
    GameRuleNode(
      id: 'gate-unfinished',
      kind: GameRuleKind.inverter,
      children: ['gate-complete'],
    ),
    GameRuleNode.predicate(
      'gate-complete',
      'game.objective-complete',
      arguments: {'objective': 'gate'},
    ),
    GameRuleNode.action(
      'gate-credit',
      'game.credit-objective',
      arguments: {'objective': 'gate', 'count': 1},
    ),
    GameRuleNode.action(
      'hide-gate',
      'game.set-active',
      arguments: {'target': 'gate', 'active': false},
    ),
    GameRuleNode.sequence('credit-checkpoint', [
      'checkpoint-near',
      'checkpoint-unfinished',
      'checkpoint-credit',
    ]),
    GameRuleNode.predicate(
      'checkpoint-near',
      'game.within',
      arguments: {'target': 'checkpoint', 'distance': 2.0},
    ),
    GameRuleNode(
      id: 'checkpoint-unfinished',
      kind: GameRuleKind.inverter,
      children: ['checkpoint-complete'],
    ),
    GameRuleNode.predicate(
      'checkpoint-complete',
      'game.objective-complete',
      arguments: {'objective': 'checkpoint'},
    ),
    GameRuleNode.action(
      'checkpoint-credit',
      'game.credit-objective',
      arguments: {'objective': 'checkpoint', 'count': 1},
    ),
  ],
);
