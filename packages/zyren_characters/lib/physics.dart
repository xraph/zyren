/// Optional root-motion adapter for the shared native physics world.
library;

import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'zyren_characters.dart';

/// Call once from PhysicsPlugin.beforeStep. The plugin steps and synchronizes
/// the outer object; animation only writes the imported pose beneath it.
final class CharacterMotor {
  final CharacterAnimationPlugin character;
  final RootMotion rootMotion;
  final KinematicCharacterController controller;
  final double gravity, terminalSpeed;
  double _verticalSpeed = 0;
  CharacterMovement? lastMovement;
  bool? _restoredGrounded;
  CharacterMotor({
    required this.character,
    required this.rootMotion,
    required this.controller,
    this.gravity = -9.81,
    this.terminalSpeed = 50,
  }) {
    if (!character.timeline.externallyDriven ||
        !gravity.isFinite ||
        gravity > 0 ||
        !terminalSpeed.isFinite ||
        terminalSpeed <= 0) {
      throw ArgumentError('Motor needs an external clock and valid gravity.');
    }
  }
  bool get grounded => _restoredGrounded ?? lastMovement?.grounded ?? false;
  Map<String, Object?> captureState() => Map.unmodifiable({
    'version': 1,
    'verticalSpeed': _verticalSpeed,
    'grounded': grounded,
    'animation': character.captureState(),
  });
  void validateState(Map<String, Object?> state) {
    final speed = state['verticalSpeed'], animation = state['animation'];
    if (state.length != 4 ||
        state['version'] != 1 ||
        speed is! num ||
        !speed.isFinite ||
        speed.abs() > terminalSpeed ||
        state['grounded'] is! bool ||
        animation is! Map<String, Object?>) {
      throw const FormatException('Invalid character motor checkpoint.');
    }
    character.validateState(animation);
  }

  void restoreState(Map<String, Object?> state) {
    validateState(state);
    character.restoreState(state['animation'] as Map<String, Object?>);
    _verticalSpeed = (state['verticalSpeed'] as num).toDouble();
    _restoredGrounded = state['grounded'] as bool;
    lastMovement = null;
  }

  void jump(double speed) {
    if (!speed.isFinite || speed <= 0 || speed > terminalSpeed) {
      throw ArgumentError('Invalid jump speed.');
    }
    if (!grounded) throw StateError('Jump requires a grounded character.');
    _verticalSpeed = speed;
  }

  CharacterMovement advance(
    Duration step, {
    Vec3 Function(double distance)? steer,
  }) {
    final seconds = step.inMicroseconds / Duration.microsecondsPerSecond;
    if ((seconds - controller.body.world.fixedStep).abs() > 1e-6) {
      throw ArgumentError('Motor must use the physics fixed step.');
    }
    final pose = controller.body.state.pose;
    final delta = rootMotion.advance(character, step);
    var rotation =
        (pose.rotation * Quat.axisAngle(const Vec3(0, 1, 0), delta.yaw))
            .normalized();
    var desired = rotation.rotate(delta.translation);
    if (steer != null) {
      desired = steer(Vec3(delta.translation.x, 0, delta.translation.z).length);
      if (!desired.isFinite) {
        throw ArgumentError('Steering intent must be finite.');
      }
      if (desired.x * desired.x + desired.z * desired.z > 1e-12) {
        rotation = Quat.axisAngle(
          const Vec3(0, 1, 0),
          math.atan2(desired.x, desired.z),
        );
      }
    }
    _verticalSpeed = math.max(
      -terminalSpeed,
      _verticalSpeed + gravity * seconds,
    );
    final movement = controller.resolve(
      desired + Vec3(0, _verticalSpeed * seconds, 0),
    );
    controller.body.setTarget(
      PhysicsPose(
        position: pose.position + movement.translation,
        rotation: rotation,
      ),
    );
    if (movement.grounded && _verticalSpeed < 0) _verticalSpeed = 0;
    if (movement.contacts.any((c) => c.normal.y < -.5) && _verticalSpeed > 0) {
      _verticalSpeed = 0;
    }
    _restoredGrounded = null;
    lastMovement = movement;
    return movement;
  }
}
