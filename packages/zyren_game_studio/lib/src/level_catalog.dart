part of '../levels.dart';

GameAuthoring createGameDevelopmentAuthoring({GameRuleLibrary? rules}) {
  final library = rules ?? GameRuleLibrary();
  final registry = GameRegistry();
  registerGameComponentCodecs(registry);
  registerGameLevelCodecs(registry);
  registry.registerComponent(
    GameRuleComponentCodec(library.actions, library.predicates),
  );
  registry.registerComponent(
    GameStateMachineComponentCodec(library.actions, library.predicates),
  );
  return GameAuthoring(
    registry,
    descriptors: [
      ...createGameComponentCatalog(),
      GameComponentDescriptor(
        type: 'game.state-machine',
        label: 'State machine',
        defaults: GameStateMachineDefinition(
          initial: 'idle',
          states: {
            'idle': GameRuleDefinition(
              graph: GameRuleGraph(
                root: 'root',
                nodes: [GameRuleNode.sequence('root', [])],
              ),
            ),
          },
          transitions: [],
        ).toJson(),
        fields: const [
          GameFieldDescriptor('initial', 'Initial state', GameFieldKind.text),
          GameFieldDescriptor('states', 'States', GameFieldKind.json),
          GameFieldDescriptor('transitions', 'Transitions', GameFieldKind.json),
        ],
      ),
      GameComponentDescriptor(
        type: 'game.level-settings',
        label: 'Level settings',
        defaults: {'profile': GameBuildProfile(id: 'native').toJson()},
        fields: const [
          GameFieldDescriptor('profile', 'Build profile', GameFieldKind.json),
          GameFieldDescriptor(
            'navigation',
            'Navigation bake',
            GameFieldKind.json,
            required: false,
          ),
        ],
      ),
      GameComponentDescriptor(
        type: 'game.collider',
        label: 'Collider',
        defaults: GameColliderDefinition().toJson(),
        fields: [
          GameFieldDescriptor(
            'shape',
            'Shape',
            GameFieldKind.choice,
            choices: GameColliderShape.values.map((v) => v.name).toList(),
          ),
          GameFieldDescriptor(
            'motion',
            'Motion',
            GameFieldKind.choice,
            choices: GameBodyMotion.values.map((v) => v.name).toList(),
          ),
          const GameFieldDescriptor(
            'halfExtents',
            'Box half extents',
            GameFieldKind.vector,
            unit: 'm',
          ),
          const GameFieldDescriptor(
            'radius',
            'Radius',
            GameFieldKind.number,
            minimum: double.minPositive,
            maximum: 1000,
            unit: 'm',
          ),
          const GameFieldDescriptor(
            'halfHeight',
            'Capsule half height',
            GameFieldKind.number,
            minimum: 0,
            maximum: 1000,
            unit: 'm',
          ),
          const GameFieldDescriptor(
            'mass',
            'Mass',
            GameFieldKind.number,
            minimum: double.minPositive,
            maximum: 1e7,
            unit: 'kg',
          ),
          const GameFieldDescriptor(
            'friction',
            'Friction',
            GameFieldKind.number,
            minimum: 0,
            maximum: 10,
          ),
          const GameFieldDescriptor(
            'restitution',
            'Restitution',
            GameFieldKind.number,
            minimum: 0,
            maximum: 1,
          ),
          const GameFieldDescriptor(
            'sensor',
            'Sensor only',
            GameFieldKind.boolean,
          ),
        ],
      ),
      GameComponentDescriptor(
        type: 'game.spawn',
        label: 'Spawn',
        defaults: {'group': 'default'},
        fields: const [
          GameFieldDescriptor('group', 'Group', GameFieldKind.text),
        ],
      ),
      GameComponentDescriptor(
        type: 'game.checkpoint',
        label: 'Checkpoint',
        defaults: {'radius': 2.0},
        fields: const [
          GameFieldDescriptor('spawn', 'Respawn entity', GameFieldKind.entity),
          GameFieldDescriptor(
            'radius',
            'Radius',
            GameFieldKind.number,
            minimum: double.minPositive,
            maximum: 1000,
            unit: 'm',
          ),
        ],
      ),
      GameComponentDescriptor(
        type: 'game.level-link',
        label: 'Level link',
        defaults: {'level': 'next-level', 'spawnGroup': 'default'},
        fields: const [
          GameFieldDescriptor('level', 'Level ID', GameFieldKind.text),
          GameFieldDescriptor('spawnGroup', 'Spawn group', GameFieldKind.text),
        ],
      ),
      GameComponentDescriptor(
        type: 'game.rules',
        label: 'Rules',
        defaults: GameRuleDefinition(
          graph: GameRuleGraph(
            root: 'root',
            nodes: [GameRuleNode.sequence('root', [])],
          ),
        ).toJson(),
        fields: const [
          GameFieldDescriptor('graph', 'Behavior graph', GameFieldKind.json),
          GameFieldDescriptor('repeat', 'Repeat', GameFieldKind.boolean),
        ],
      ),
    ],
  );
}
