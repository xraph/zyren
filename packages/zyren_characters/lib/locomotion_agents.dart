/// Optional locomotion and rig tools. Host commands own persistence and undo.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'physics.dart';
import 'zyren_characters.dart';

final class CharacterLocomotionAgentProvider extends AgentProvider {
  final CharacterMotor motor;
  final CharacterRig rig;
  @override
  final String instanceId;
  final int Function() readRevision;
  final bool Function() isAvailable;
  final void Function(String, void Function())? runCommand;
  final void Function(Vec3)? moveTo, lookAt;
  final void Function(int, Vec3)? footTarget;
  final void Function(bool)? retarget;
  CharacterLocomotionAgentProvider({
    required this.motor,
    required this.rig,
    required this.instanceId,
    required this.readRevision,
    required this.isAvailable,
    this.runCommand,
    this.moveTo,
    this.lookAt,
    this.footTarget,
    this.retarget,
  });
  @override
  String get id => 'zyren.characters.locomotion';
  @override
  String get version => '1.0.0';
  @override
  int get revision => readRevision();
  Registration register(AgentRegistry registry, AttachmentScope scope) =>
      scope.keep(registry.register(this));
  @override
  Map<String, Object?> get capabilities => {
    'rootMotion': 'fixed-step-translation-yaw',
    'controller': 'native-capsule',
    'IK': 'two-bone-and-look-at',
    'retargeting': 'explicit-bind-rig-map',
    'units': 'metres',
    'up': 'Y',
  };
  static const _vector = {
    'type': 'array',
    'items': {'type': 'number', 'minimum': -10000, 'maximum': 10000},
    'minItems': 3,
    'maxItems': 3,
  };
  static const _out = {'type': 'object', 'additionalProperties': true};
  AgentTool command(
    String name,
    String description,
    Map<String, Object?> properties,
    List<String> required,
  ) => AgentTool(
    name: name,
    description: description,
    readOnly: false,
    requiredScopes: const {'characters.locomotion'},
    inputSchema: {
      'type': 'object',
      'properties': properties,
      'required': required,
      'additionalProperties': false,
    },
    outputSchema: _out,
  );
  @override
  List<AgentTool> get tools => [
    AgentTool(
      name: 'inspect',
      description:
          'Read root motion, grounding, controller settings and explicit rig IDs.',
      inputSchema: const {'type': 'object', 'additionalProperties': false},
      outputSchema: _out,
    ),
    if (runCommand != null) ...[
      if (moveTo != null)
        command(
          'move_to',
          'Set a world-space route goal through the host controller.',
          {'target': _vector},
          ['target'],
        ),
      if (lookAt != null)
        command(
          'look_at',
          'Set a model-space target for the bounded head solver.',
          {'target': _vector},
          ['target'],
        ),
      if (footTarget != null)
        command(
          'foot_target',
          'Set a model-space contact target for a host-exposed leg.',
          {
            'joint': {'type': 'integer', 'minimum': 0},
            'target': _vector,
          },
          ['joint', 'target'],
        ),
      if (retarget != null)
        command(
          'set_retarget',
          'Enable or disable the host-owned target rig.',
          {
            'enabled': {'type': 'boolean'},
          },
          ['enabled'],
        ),
      command(
        'jump',
        'Jump only when the native controller reports grounded.',
        {
          'speed': {
            'type': 'number',
            'exclusiveMinimum': 0,
            'maximum': motor.terminalSpeed,
          },
        },
        ['speed'],
      ),
    ],
  ];
  Map<String, Object?> _inspect() => {
    'root': motor.rootMotion.root,
    'grounded': motor.grounded,
    'position': motor.controller.body.state.pose.position.storage,
    'settings': motor.controller.settings.json,
    'joints': rig.joints,
    'paused': motor.character.isPaused,
    'contacts': [
      for (final c in motor.lastMovement?.contacts ?? [])
        {'collider': c.collider, 'body': c.body, 'normal': c.normal.storage},
    ],
  };
  @override
  AgentResult invoke(
    String tool,
    Map<String, Object?> arguments,
    AgentCallContext context,
  ) {
    context.checkCancelled();
    if (!isAvailable() || !motor.controller.body.isAlive) {
      return AgentResult(AgentStatus.stale);
    }
    if (tool == 'inspect') {
      return AgentResult(AgentStatus.ok, data: _inspect(), revision: revision);
    }
    if (runCommand == null) return AgentResult(AgentStatus.unsupported);
    Vec3 target() {
      final v = arguments['target'] as List;
      return Vec3(
        (v[0] as num).toDouble(),
        (v[1] as num).toDouble(),
        (v[2] as num).toDouble(),
      );
    }

    void Function() apply;
    switch (tool) {
      case 'move_to' when moveTo != null:
        final value = target();
        apply = () => moveTo!(value);
      case 'look_at' when lookAt != null:
        final value = target();
        apply = () => lookAt!(value);
      case 'foot_target' when footTarget != null:
        final joint = arguments['joint'] as int, value = target();
        if (!rig.joints.values.contains(joint)) {
          return AgentResult(
            AgentStatus.invalid,
            message: 'Unknown rig joint.',
          );
        }
        apply = () => footTarget!(joint, value);
      case 'set_retarget' when retarget != null:
        apply = () => retarget!(arguments['enabled'] as bool);
      case 'jump':
        apply = () => motor.jump((arguments['speed'] as num).toDouble());
      default:
        return AgentResult(AgentStatus.unsupported);
    }
    runCommand!(tool, () {
      context.checkCancelled();
      if (!isAvailable()) throw StateError('Character was removed.');
      apply();
    });
    return AgentResult(AgentStatus.ok, data: _inspect(), revision: revision);
  }
}
