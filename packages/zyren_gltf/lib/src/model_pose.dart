part of 'loader.dart';

/// A complete immutable local pose, tied to its model template and scene nodes.
final class ModelPose {
  final _SharedModel _template;
  final Map<int, ({Vec3 position, Quat rotation, Vec3 scale})> nodes;
  final Map<int, List<double>> weights;
  bool sharesTemplateWith(ModelPose other) =>
      identical(_template, other._template);

  /// Replaces selected local transforms, preserving node and template identity.
  ModelPose withNodes(
    Map<int, ({Vec3 position, Quat rotation, Vec3 scale})> edits,
  ) {
    for (final e in edits.entries) {
      if (!nodes.containsKey(e.key) ||
          !e.value.position.isFinite ||
          !e.value.scale.isFinite ||
          e.value.scale.x == 0 ||
          e.value.scale.y == 0 ||
          e.value.scale.z == 0) {
        throw ArgumentError(
          'Pose edits need existing nodes and invertible finite TRS.',
        );
      }
      e.value.rotation.normalized();
    }
    return ModelPose._(_template, {...nodes, ...edits}, weights);
  }

  ModelPose._(
    this._template,
    Map<int, ({Vec3 position, Quat rotation, Vec3 scale})> nodes,
    Map<int, List<double>> weights,
  ) : nodes = Map.unmodifiable(nodes),
      weights = Map.unmodifiable(
        weights.map(
          (key, value) => MapEntry(key, List<double>.unmodifiable(value)),
        ),
      );
}

final class ModelPoseContribution {
  final ModelPose pose;
  final double weight;
  final ModelPose? reference;
  ModelPoseContribution(this.pose, this.weight, {this.reference}) {
    if (!weight.isFinite || weight < 0 || weight > 1) {
      throw ArgumentError('Pose weights must fit zero to one.');
    }
  }
}

ModelPose _blendModelPoses(
  List<ModelPoseContribution> source,
  List<ModelPoseContribution> additions,
) {
  final active = source.where((v) => v.weight > 0).toList();
  if (active.isEmpty) {
    throw ArgumentError('At least one absolute pose must contribute.');
  }
  final total = active.fold<double>(0, (sum, v) => sum + v.weight);
  var dominant = active.first;
  for (final entry in active.skip(1)) {
    if (entry.weight > dominant.weight) dominant = entry;
  }
  final nodes = <int, ({Vec3 position, Quat rotation, Vec3 scale})>{};
  final weights = <int, List<double>>{};
  for (final node in dominant.pose.nodes.keys) {
    final reference = dominant.pose.nodes[node]!;
    var p = Vec3.zero, s = Vec3.zero;
    var x = 0.0, y = 0.0, z = 0.0, w = 0.0;
    for (final entry in active) {
      final pose = entry.pose.nodes[node]!, weight = entry.weight / total;
      if (pose.scale.x.sign != reference.scale.x.sign ||
          pose.scale.y.sign != reference.scale.y.sign ||
          pose.scale.z.sign != reference.scale.z.sign) {
        throw ArgumentError('Mixed pose scales must keep matching signs.');
      }
      p += pose.position * weight;
      s += pose.scale * weight;
      final a = reference.rotation, b = pose.rotation;
      final aligned = (a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w) < 0
          ? -weight
          : weight;
      x += b.x * aligned;
      y += b.y * aligned;
      z += b.z * aligned;
      w += b.w * aligned;
    }
    nodes[node] = (
      position: p,
      rotation: Quat(x, y, z, w).normalized(),
      scale: s,
    );
  }
  for (final node in dominant.pose.weights.keys) {
    final count = dominant.pose.weights[node]!.length;
    final blended = List<double>.filled(count, 0);
    for (final entry in active) {
      final values = entry.pose.weights[node];
      if (values == null || values.length != count) {
        throw ArgumentError('Morph pose dimensions must match.');
      }
      for (var i = 0; i < count; i++) {
        blended[i] += values[i] * entry.weight / total;
      }
    }
    weights[node] = blended;
  }
  for (final entry in additions) {
    if (entry.weight == 0) continue;
    final reference = entry.reference;
    if (reference == null) {
      throw ArgumentError('An additive pose requires a reference.');
    }
    for (final node in nodes.keys.toList()) {
      final pose = nodes[node]!,
          sample = entry.pose.nodes[node]!,
          ref = reference.nodes[node]!;
      double scale(double value, double base) {
        final ratio = value / base;
        if (!ratio.isFinite || ratio <= 0) {
          throw ArgumentError('Additive scale must keep reference signs.');
        }
        return 1 + (ratio - 1) * entry.weight;
      }

      final q = ref.rotation;
      final delta = Quat(-q.x, -q.y, -q.z, q.w) * sample.rotation;
      nodes[node] = (
        position:
            pose.position + (sample.position - ref.position) * entry.weight,
        rotation: (pose.rotation * _poseSlerp(delta, entry.weight))
            .normalized(),
        scale: Vec3(
          pose.scale.x * scale(sample.scale.x, ref.scale.x),
          pose.scale.y * scale(sample.scale.y, ref.scale.y),
          pose.scale.z * scale(sample.scale.z, ref.scale.z),
        ),
      );
    }
    for (final node in weights.keys) {
      final values = entry.pose.weights[node],
          baseline = reference.weights[node],
          out = weights[node]!;
      if (values == null ||
          baseline == null ||
          values.length != out.length ||
          baseline.length != out.length) {
        throw ArgumentError('Additive morph dimensions must match.');
      }
      for (var i = 0; i < out.length; i++) {
        out[i] += (values[i] - baseline[i]) * entry.weight;
      }
    }
  }
  return ModelPose._(dominant.pose._template, nodes, weights);
}

Quat _poseSlerp(Quat delta, double weight) {
  var q = delta.normalized();
  if (q.w < 0) q = Quat(-q.x, -q.y, -q.z, -q.w);
  var left = 1 - weight, right = weight;
  if (q.w < .9995) {
    final angle = math.acos(q.w.clamp(-1.0, 1.0));
    left = math.sin((1 - weight) * angle) / math.sin(angle);
    right = math.sin(weight * angle) / math.sin(angle);
  }
  return Quat(
    q.x * right,
    q.y * right,
    q.z * right,
    left + q.w * right,
  ).normalized();
}
