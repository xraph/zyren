import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'rig.dart';

final class IkResult {
  final ModelPose pose;
  final double error;
  final bool limited;
  const IkResult(this.pose, this.error, this.limited);
}

/// Analytic two-bone solve in model coordinates. Bend angles use 0 for straight.
final class TwoBoneIk {
  final CharacterRig rig;
  final int upper, lower, end;
  final double minBend, maxBend;
  TwoBoneIk(
    this.rig, {
    required this.upper,
    required this.lower,
    required this.end,
    this.minBend = .001,
    this.maxBend = math.pi - .001,
  }) {
    if (rig.parents[lower] != upper ||
        rig.parents[end] != lower ||
        !minBend.isFinite ||
        !maxBend.isFinite ||
        minBend < 0 ||
        maxBend >= math.pi ||
        maxBend < minBend) {
      throw ArgumentError(
        'IK needs a direct joint chain and valid bend limits.',
      );
    }
    final bind = rig.world(rig.bindPose);
    if (bind[upper]!.position.distanceTo(bind[lower]!.position) < 1e-6 ||
        bind[lower]!.position.distanceTo(bind[end]!.position) < 1e-6) {
      throw ArgumentError('IK bones must have nonzero lengths.');
    }
  }
  IkResult solve(
    ModelPose pose, {
    required Vec3 target,
    required Vec3 pole,
    double weight = 1,
  }) {
    if (!target.isFinite || !pole.isFinite) {
      throw ArgumentError('IK inputs must be finite.');
    }
    var world = rig.world(pose);
    final a = world[upper]!.position,
        b = world[lower]!.position,
        c = world[end]!.position;
    final l1 = a.distanceTo(b), l2 = b.distanceTo(c), offset = target - a;
    if (l1 < 1e-6 || l2 < 1e-6) {
      throw ArgumentError('Animated IK bones collapsed.');
    }
    final direction = offset.length > 1e-8
        ? offset.normalized()
        : (c - a).length > 1e-8
        ? (c - a).normalized()
        : (b - a).normalized();
    final maxReach = math.sqrt(
      l1 * l1 + l2 * l2 + 2 * l1 * l2 * math.cos(minBend),
    );
    final minReach = math.max(
      1e-7,
      math.sqrt(l1 * l1 + l2 * l2 + 2 * l1 * l2 * math.cos(maxBend)),
    );
    final distance = offset.length.clamp(minReach, maxReach);
    var bend = pole - a - direction * (pole - a).dot(direction);
    if (bend.length < 1e-8) {
      bend = direction.cross(
        direction.x.abs() < .8 ? const Vec3(1, 0, 0) : const Vec3(0, 1, 0),
      );
    }
    bend = bend.normalized();
    final along = (l1 * l1 - l2 * l2 + distance * distance) / (2 * distance);
    final knee =
        a +
        direction * along +
        bend * math.sqrt(math.max(0, l1 * l1 - along * along));
    final goal = a + direction * distance;
    var solved = rig.rotateWorld(
      pose,
      upper,
      rotationBetween(b - a, knee - a) * world[upper]!.rotation,
    );
    world = rig.world(solved);
    solved = rig.rotateWorld(
      solved,
      lower,
      rotationBetween(
            world[end]!.position - world[lower]!.position,
            goal - world[lower]!.position,
          ) *
          world[lower]!.rotation,
    );
    if (weight != 1) {
      solved = pose.withNodes({
        for (final id in [upper, lower])
          id: (
            position: pose.nodes[id]!.position,
            scale: pose.nodes[id]!.scale,
            rotation: blendRotation(
              pose.nodes[id]!.rotation,
              solved.nodes[id]!.rotation,
              weight,
            ),
          ),
      });
    }
    return IkResult(
      solved,
      rig.world(solved)[end]!.position.distanceTo(target),
      (distance - offset.length).abs() > 1e-6,
    );
  }
}

/// Bounded swing toward a target, preserving the joint's existing roll.
final class LookAtIk {
  final CharacterRig rig;
  final int joint;
  final Vec3 forward;
  final double maxAngle;
  LookAtIk(
    this.rig, {
    required this.joint,
    this.forward = const Vec3(0, 0, 1),
    this.maxAngle = math.pi / 3,
  }) {
    if (!rig.parents.containsKey(joint) ||
        !forward.isFinite ||
        forward.length < 1e-8 ||
        !maxAngle.isFinite ||
        maxAngle < 0 ||
        maxAngle > math.pi) {
      throw ArgumentError('Invalid look-at joint, axis or swing limit.');
    }
  }
  ModelPose solve(ModelPose pose, Vec3 target, {double weight = 1}) {
    if (!target.isFinite || !weight.isFinite || weight < 0 || weight > 1) {
      throw ArgumentError('Target must be finite and weight must fit [0,1].');
    }
    final transform = rig.world(pose)[joint]!;
    final to = target - transform.position;
    if (to.length < 1e-8) return pose;
    final direction = transform.rotation.rotate(forward).normalized();
    final angle = math.acos(direction.dot(to.normalized()).clamp(-1.0, 1.0));
    final rotation = rotationBetween(direction, to) * transform.rotation;
    return rig.rotateWorld(
      pose,
      joint,
      rotation,
      weight: weight * (angle <= maxAngle ? 1 : maxAngle / angle),
    );
  }
}
