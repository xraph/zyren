import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';

typedef RigTransform = ({Vec3 position, Quat rotation, double scale});
Quat inverseRotation(Quat q) => Quat(-q.x, -q.y, -q.z, q.w).normalized();
Quat rotationBetween(Vec3 from, Vec3 to) {
  final a = from.normalized(),
      b = to.normalized(),
      dot = a.dot(b).clamp(-1.0, 1.0);
  if (dot > 1 - 1e-12) return Quat.identity;
  if (dot < -1 + 1e-12) {
    final axis = a.cross(
      a.x.abs() < .8 ? const Vec3(1, 0, 0) : const Vec3(0, 1, 0),
    );
    return Quat.axisAngle(axis, math.pi);
  }
  final cross = a.cross(b);
  return Quat(cross.x, cross.y, cross.z, 1 + dot).normalized();
}

Quat blendRotation(Quat a, Quat b, double weight) {
  if (!weight.isFinite || weight < 0 || weight > 1) {
    throw ArgumentError('Weight must fit [0,1].');
  }
  var delta = inverseRotation(a) * b;
  if (delta.w < 0) delta = Quat(-delta.x, -delta.y, -delta.z, -delta.w);
  final angle = 2 * math.acos(delta.w.clamp(-1.0, 1.0));
  final axis = Vec3(delta.x, delta.y, delta.z);
  return axis.length2 < 1e-20
      ? a
      : (a * Quat.axisAngle(axis, angle * weight)).normalized();
}

/// Explicit source node IDs and bind transforms, independent of display names.
/// Joint ancestry must retain positive uniform scales for rigid IK rotations.
final class CharacterRig {
  final ModelInstance model;
  final Map<String, int> joints;
  final ModelPose bindPose;
  final Map<int, int?> parents;
  final List<int> order;
  factory CharacterRig(
    ModelInstance model, {
    required Map<String, int> joints,
  }) {
    if (joints.isEmpty ||
        joints.length > 256 ||
        joints.values.toSet().length != joints.length ||
        joints.keys.any((v) => v.trim().isEmpty)) {
      throw ArgumentError('Use 1 to 256 unique named joints.');
    }
    final ids = {for (final e in model.nodes.entries) e.value: e.key};
    final parents = <int, int?>{};
    void visit(int id) {
      if (parents.containsKey(id)) return;
      final node = model.nodes[id];
      if (node == null) throw ArgumentError('Unknown rig node $id.');
      final parent = ids[node.parent];
      if (parent != null) visit(parent);
      parents[id] = parent;
    }

    for (final id in joints.values) {
      visit(id);
    }
    final pose = model.samplePose(initial: true);
    for (final id in parents.keys) {
      final s = pose.nodes[id]!.scale;
      if (s.x <= 0 || (s.x - s.y).abs() > 1e-9 || (s.x - s.z).abs() > 1e-9) {
        throw ArgumentError('Rig ancestry requires positive uniform scale.');
      }
    }
    return CharacterRig._(
      model,
      Map.unmodifiable(joints),
      pose,
      Map.unmodifiable(parents),
      List.unmodifiable(parents.keys),
    );
  }
  CharacterRig._(
    this.model,
    this.joints,
    this.bindPose,
    this.parents,
    this.order,
  );
  Map<int, RigTransform> world(ModelPose pose) {
    if (!pose.sharesTemplateWith(bindPose)) {
      throw ArgumentError('Pose belongs to another rig template.');
    }
    final out = <int, RigTransform>{};
    for (final id in order) {
      final local = pose.nodes[id];
      if (local == null) throw ArgumentError('Pose is missing rig node $id.');
      final s = local.scale;
      if (s.x <= 0 || (s.x - s.y).abs() > 1e-9 || (s.x - s.z).abs() > 1e-9) {
        throw ArgumentError(
          'Animated joint scales must remain positive and uniform.',
        );
      }
      final parent = out[parents[id]];
      out[id] = parent == null
          ? (
              position: local.position,
              rotation: local.rotation.normalized(),
              scale: s.x,
            )
          : (
              position:
                  parent.position +
                  parent.rotation.rotate(local.position * parent.scale),
              rotation: (parent.rotation * local.rotation).normalized(),
              scale: parent.scale * s.x,
            );
    }
    return out;
  }

  ModelPose rotateWorld(
    ModelPose pose,
    int node,
    Quat rotation, {
    double weight = 1,
  }) {
    if (!parents.containsKey(node)) throw ArgumentError('Node is outside rig.');
    final parent = world(pose)[parents[node]];
    final local = pose.nodes[node]!;
    final desired = parent == null
        ? rotation
        : inverseRotation(parent.rotation) * rotation;
    return pose.withNodes({
      node: (
        position: local.position,
        rotation: blendRotation(local.rotation, desired, weight),
        scale: local.scale,
      ),
    });
  }
}
