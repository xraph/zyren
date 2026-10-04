/// Typed editor defaults backed by the runtime component codecs.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'authoring.dart';
export 'authoring.dart';

/// A supplied registry may contain custom codecs; built-ins register once here.
GameAuthoring createGameAuthoring({GameRegistry? registry}) {
  final codecs = registry ?? GameRegistry();
  registerGameComponentCodecs(codecs);
  return GameAuthoring(codecs, descriptors: createGameComponentCatalog());
}

List<GameComponentDescriptor> createGameComponentCatalog() {
  final character = GameCharacterDefinition();
  final vehicle = VehicleDefinition(
    wheels: [
      for (final z in [-1.0, 1.0])
        for (final x in [-.7, .7])
          WheelDefinition(
            id: '${z > 0 ? 'front' : 'rear'}-${x > 0 ? 'right' : 'left'}',
            mount: Vec3(x, 0, z),
            steering: z > 0,
          ),
    ],
  );
  final camera = GameCameraDefinition();
  final interaction = GameInteractionDefinition();
  final input = GameInputMap(
    actions: [
      GameActionDefinition('move.x', deadZone: .12),
      GameActionDefinition('move.z', deadZone: .12),
      GameActionDefinition('look.yaw', deadZone: .12),
      GameActionDefinition('look.pitch', deadZone: .12),
      GameActionDefinition('jump', button: true),
      GameActionDefinition('interact', button: true),
    ],
    bindings: [
      GameInputBinding('key.w', 'move.z'),
      GameInputBinding('key.s', 'move.z', scale: -1),
      GameInputBinding('key.a', 'move.x', scale: -1),
      GameInputBinding('key.d', 'move.x'),
      GameInputBinding('key.space', 'jump'),
      GameInputBinding('key.e', 'interact'),
      GameInputBinding('axis.leftStickX', 'move.x'),
      GameInputBinding('axis.leftStickY', 'move.z'),
      GameInputBinding('axis.rightStickX', 'look.yaw'),
      GameInputBinding('axis.rightStickY', 'look.pitch'),
      GameInputBinding('button.a', 'jump'),
      GameInputBinding('button.x', 'interact'),
      GameInputBinding('button.dpadUp', 'move.z'),
      GameInputBinding('button.dpadDown', 'move.z', scale: -1),
      GameInputBinding('button.dpadLeft', 'move.x', scale: -1),
      GameInputBinding('button.dpadRight', 'move.x'),
    ],
  );
  return List.unmodifiable([
    GameComponentDescriptor(
      type: 'game.character',
      label: 'Character',
      defaults: character.toJson(),
      fields: const [
        GameFieldDescriptor(
          'maxSpeed',
          'Maximum speed',
          GameFieldKind.number,
          minimum: 0,
          maximum: 100,
          unit: 'm/s',
        ),
        GameFieldDescriptor(
          'jumpSpeed',
          'Jump speed',
          GameFieldKind.number,
          minimum: 0,
          maximum: 50,
          unit: 'm/s',
        ),
        GameFieldDescriptor(
          'groundStickSpeed',
          'Ground contact speed',
          GameFieldKind.number,
          minimum: 0,
          maximum: 5,
          unit: 'm/s',
        ),
        GameFieldDescriptor('idleState', 'Idle state', GameFieldKind.text),
        GameFieldDescriptor('movingState', 'Moving state', GameFieldKind.text),
      ],
    ),
    GameComponentDescriptor(
      type: 'game.vehicle',
      label: 'Vehicle',
      defaults: vehicle.toJson(),
      fields: [
        const GameFieldDescriptor(
          'mass',
          'Chassis mass',
          GameFieldKind.number,
          minimum: 1,
          maximum: 100000,
          unit: 'kg',
        ),
        const GameFieldDescriptor(
          'wheelbase',
          'Wheelbase',
          GameFieldKind.number,
          minimum: .1,
          maximum: 50,
          unit: 'm',
        ),
        const GameFieldDescriptor(
          'trackWidth',
          'Track width',
          GameFieldKind.number,
          minimum: .1,
          maximum: 30,
          unit: 'm',
        ),
        const GameFieldDescriptor(
          'engineForce',
          'Drive force',
          GameFieldKind.number,
          minimum: 0,
          maximum: 1e7,
          unit: 'N',
        ),
        const GameFieldDescriptor(
          'brakeForce',
          'Brake force',
          GameFieldKind.number,
          minimum: 0,
          maximum: 1e7,
          unit: 'N',
        ),
        const GameFieldDescriptor(
          'maxSteerAngle',
          'Maximum steering',
          GameFieldKind.number,
          minimum: .001,
          maximum: 1.2,
          unit: 'rad',
        ),
        const GameFieldDescriptor(
          'maxSpeed',
          'Maximum speed',
          GameFieldKind.number,
          minimum: .1,
          maximum: 150,
          unit: 'm/s',
        ),
        const GameFieldDescriptor(
          'tireFriction',
          'Tire friction',
          GameFieldKind.number,
          minimum: 0,
          maximum: 5,
        ),
        const GameFieldDescriptor(
          'lostControlBrake',
          'Brake on lost control',
          GameFieldKind.number,
          minimum: 0,
          maximum: 1,
        ),
        GameFieldDescriptor(
          'wheels',
          'Wheels',
          GameFieldKind.json,
          entryBatchSize: 2,
          entryTemplate: Map.unmodifiable(
            WheelDefinition(
              id: 'new-wheel',
              mount: const Vec3(.7, 0, 0),
              steering: false,
            ).toJson(),
          ),
        ),
      ],
    ),
    GameComponentDescriptor(
      type: 'game.camera',
      label: 'Camera',
      defaults: camera.toJson(),
      fields: [
        GameFieldDescriptor(
          'mode',
          'View',
          GameFieldKind.choice,
          choices: List.unmodifiable(GameCameraMode.values.map((m) => m.name)),
        ),
        const GameFieldDescriptor(
          'target',
          'Follow target',
          GameFieldKind.entity,
          required: false,
        ),
        const GameFieldDescriptor(
          'radius',
          'Collision radius',
          GameFieldKind.number,
          minimum: double.minPositive,
          maximum: 2,
          unit: 'm',
        ),
        const GameFieldDescriptor(
          'eyeHeight',
          'Eye height',
          GameFieldKind.number,
          minimum: 0,
          maximum: 10,
          unit: 'm',
        ),
        const GameFieldDescriptor(
          'thirdPersonDistance',
          'Third person distance',
          GameFieldKind.number,
          minimum: double.minPositive,
          maximum: 100,
          unit: 'm',
        ),
        const GameFieldDescriptor(
          'vehicleDistance',
          'Vehicle distance',
          GameFieldKind.number,
          minimum: double.minPositive,
          maximum: 100,
          unit: 'm',
        ),
      ],
    ),
    GameComponentDescriptor(
      type: 'game.input',
      label: 'Input',
      defaults: input.toJson(),
      fields: const [
        GameFieldDescriptor(
          'actions',
          'Actions',
          GameFieldKind.json,
          entryTemplate: {'id': 'new-action', 'button': false, 'deadZone': 0},
        ),
        GameFieldDescriptor(
          'bindings',
          'Bindings',
          GameFieldKind.json,
          entryTemplate: {'control': 'KeyX', 'action': 'move.x', 'scale': 1},
        ),
      ],
    ),
    GameComponentDescriptor(
      type: 'game.interaction',
      label: 'Interaction',
      defaults: interaction.toJson(),
      fields: const [
        GameFieldDescriptor('id', 'Action ID', GameFieldKind.text),
        GameFieldDescriptor('label', 'Action label', GameFieldKind.text),
        GameFieldDescriptor(
          'target',
          'Target',
          GameFieldKind.entity,
          required: false,
        ),
        GameFieldDescriptor(
          'reach',
          'Reach',
          GameFieldKind.number,
          minimum: double.minPositive,
          maximum: 100,
          unit: 'm',
        ),
        GameFieldDescriptor(
          'maxCandidates',
          'Candidate limit',
          GameFieldKind.integer,
          minimum: 1,
          maximum: 128,
        ),
        GameFieldDescriptor(
          'maxTargets',
          'Target limit',
          GameFieldKind.integer,
          minimum: 1,
          maximum: 1024,
        ),
        GameFieldDescriptor(
          'requiredItems',
          'Required items',
          GameFieldKind.json,
        ),
        GameFieldDescriptor(
          'consumeItems',
          'Consume items',
          GameFieldKind.boolean,
        ),
        GameFieldDescriptor(
          'receiptCapacity',
          'Receipt capacity',
          GameFieldKind.integer,
          minimum: 1,
          maximum: 65536,
        ),
      ],
    ),
    GameComponentDescriptor(
      type: 'game.inventory',
      label: 'Inventory',
      defaults: Inventory(capacity: 100).toJson(),
      fields: const [
        GameFieldDescriptor(
          'capacity',
          'Capacity',
          GameFieldKind.integer,
          minimum: 1,
          maximum: 1000000,
          unit: 'items',
        ),
        GameFieldDescriptor('items', 'Items', GameFieldKind.json),
      ],
    ),
    GameComponentDescriptor(
      type: 'game.abilities',
      label: 'Abilities',
      dependencies: {'game.inventory'},
      defaults: GameAbilityCollection({
        'sprint': Ability(id: 'sprint', cooldownTicks: 30),
      }).toJson(),
      fields: const [
        GameFieldDescriptor(
          'abilities',
          'Abilities',
          GameFieldKind.json,
          entryTemplate: {
            'id': 'new-ability',
            'cooldownTicks': 30,
            'durationTicks': 0,
            'costs': {},
          },
        ),
      ],
    ),
    GameComponentDescriptor(
      type: 'game.objectives',
      label: 'Objectives',
      defaults: ObjectiveTracker({'checkpoint': 1}).toJson(),
      fields: const [
        GameFieldDescriptor('targets', 'Targets', GameFieldKind.json),
        GameFieldDescriptor(
          'receiptCapacity',
          'Receipt capacity',
          GameFieldKind.integer,
          minimum: 1,
          maximum: 65536,
        ),
      ],
    ),
  ]);
}
