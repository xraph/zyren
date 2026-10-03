/// Authored glTF clips bound to the existing native character motor.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_characters/physics.dart';
import 'package:zyren_characters/zyren_characters.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'runtime.dart';

/// Primitive actors return null and keep the runtime's primitive controller.
GameCharacterAnimation? createGameCharacterAnimation(
  GameEntityRecord entity,
  Object3D root,
  PhysicsBody body,
  PhysicsCollider collider,
) {
  final models = <ModelInstance>[];
  void visit(Object3D object) {
    if (object is ModelInstance) models.add(object);
    for (final child in object.children) {
      visit(child);
    }
  }

  visit(root);
  final component = entity.components
      .where((c) => c.type == 'game.character-rig')
      .firstOrNull;
  if (models.isEmpty && component == null) return null;
  if (models.length != 1 || component == null) {
    throw StateError(
      '${entity.id} needs one imported model and a Character animation rig '
      'component. Select its root motion node and clip names before play.',
    );
  }
  if (identical(models.single, root)) {
    throw StateError(
      'Keep the imported model beneath the character body group.',
    );
  }
  final rig = GameCharacterRigDefinition.fromJson(component.data);
  final character = entity.components
      .where((c) => c.type == 'game.character')
      .single;
  final definition = GameCharacterDefinition.fromComponent(character);
  final model = models.single;
  ModelAnimation clip(String name) {
    final matches = model.animations.where((a) => a.name == name).toList();
    if (matches.length != 1) {
      throw StateError(
        '${entity.id}: clip "$name" must identify one imported animation. '
        'Available clips: ${model.animations.map((a) => a.name).join(', ')}.',
      );
    }
    return matches.single;
  }

  final moving = clip(rig.movingClip);
  final idle = rig.idleClip == null ? null : clip(rig.idleClip!);
  if (!identical(model.nodes[rig.rootMotionNode]?.parent, model)) {
    throw StateError(
      '${entity.id}: root motion node ${rig.rootMotionNode} must be a '
      'top-level node in the imported model.',
    );
  }
  final motion = RootMotion(model, root: rig.rootMotionNode);
  final timeline = SceneTimelinePlugin.mixed(
    id: 'game.timeline.${entity.id}',
    duration: const Duration(seconds: 1),
    base: modelRestClip(model, process: motion.process),
  )..externallyDriven = true;
  final animation = CharacterAnimationPlugin(
    id: 'game.character-animation.${entity.id}',
    timeline: timeline,
    states: [
      if (idle == null)
        CharacterState.rest(
          definition.idleState,
          model,
          process: motion.process,
        )
      else
        CharacterState.animation(
          definition.idleState,
          model,
          idle,
          process: motion.process,
        ),
      CharacterState.animation(
        definition.movingState,
        model,
        moving,
        process: motion.process,
      ),
    ],
    transitions: [
      CharacterTransition(definition.idleState, definition.movingState),
      CharacterTransition(definition.movingState, definition.idleState),
    ],
    initialState: definition.idleState,
  );
  final motor = CharacterMotor(
    character: animation,
    rootMotion: motion,
    controller: KinematicCharacterController(body: body, collider: collider),
  );
  model.position = rig.visualOffset;
  return GameCharacterAnimation(motor, plugins: [timeline, animation]);
}
