import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'rig.dart';

/// Maps bind-relative rotations through explicit joint frames. Target bone
/// offsets stay authored; root translation uses the declared metres-per-unit.
final class RigRetargeter {
  final CharacterRig source, target;
  final Map<int, int> mapping;
  final Map<int, Quat> axisCorrections;
  final double sourceUnits, targetUnits;
  final int sourceRoot, targetRoot;
  RigRetargeter({
    required this.source,
    required this.target,
    required Map<int, int> mapping,
    required this.sourceRoot,
    required this.targetRoot,
    Map<int, Quat> axisCorrections = const {},
    this.sourceUnits = 1,
    this.targetUnits = 1,
  }) : mapping = Map.unmodifiable(mapping),
       axisCorrections = Map.unmodifiable(axisCorrections) {
    if (mapping.isEmpty ||
        mapping.values.toSet().length != mapping.length ||
        mapping[sourceRoot] != targetRoot ||
        source.parents[sourceRoot] != null ||
        target.parents[targetRoot] != null ||
        !sourceUnits.isFinite ||
        sourceUnits <= 0 ||
        !targetUnits.isFinite ||
        targetUnits <= 0 ||
        mapping.entries.any(
          (e) =>
              !source.parents.containsKey(e.key) ||
              !target.parents.containsKey(e.value),
        ) ||
        axisCorrections.keys.any((id) => !mapping.values.contains(id))) {
      throw ArgumentError(
        'Retargeting requires unique rig mappings, top-level roots and positive units.',
      );
    }
    for (final q in axisCorrections.values) {
      q.normalized();
    }
  }
  ModelPose apply(ModelPose pose) {
    final restSource = source.world(source.bindPose),
        animated = source.world(pose),
        restTarget = target.world(target.bindPose);
    var result = target.bindPose;
    final inverseMap = {for (final e in mapping.entries) e.value: e.key};
    for (final id in target.order) {
      final from = inverseMap[id];
      if (from == null) continue;
      final correction = axisCorrections[id] ?? Quat.identity;
      final delta =
          inverseRotation(restSource[from]!.rotation) *
          animated[from]!.rotation;
      final desired =
          restTarget[id]!.rotation *
          correction *
          delta *
          inverseRotation(correction);
      result = target.rotateWorld(result, id, desired);
    }
    final r = result.nodes[targetRoot]!,
        correction = axisCorrections[targetRoot] ?? Quat.identity;
    return result.withNodes({
      targetRoot: (
        position:
            target.bindPose.nodes[targetRoot]!.position +
            correction.rotate(
                  pose.nodes[sourceRoot]!.position -
                      source.bindPose.nodes[sourceRoot]!.position,
                ) *
                (sourceUnits / targetUnits),
        rotation: r.rotation,
        scale: r.scale,
      ),
    });
  }
}
