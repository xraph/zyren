part of 'loader.dart';

final class _InstanceDeformer {
  final int node;
  final Mesh mesh;
  final BufferGeometry geometry;
  final _ModelPrimitive source;
  final List<double> initialWeights;
  final int? skin;
  _InstanceDeformer(
    this.node,
    this.mesh,
    this.source,
    this.initialWeights,
    this.skin,
  ) : geometry = mesh.geometry;
}

/// Instance-specific node bindings and dynamic native geometry.
final class ModelInstance extends Group {
  final _SharedModel _template;
  final Map<int, Object3D> _nodes;
  final List<_InstanceDeformer> _deformers;
  final Map<Object3D, Object3D?> _parents = Map.identity();
  final Map<Mesh, BufferGeometry> _geometries = Map.identity();
  final Map<int, List<Mesh>> morphTargets;
  final bool _nativeDeformation;
  late final List<ModelAnimation> animations = _sceneAnimations(
    _nodes,
    _template.animations,
  );
  late final AnimationMixer mixer = _createMixer();
  AnimationMixer _createMixer() {
    if (!_nativeDeformation && _deformers.isNotEmpty) {
      throw StateError(
        'CPU deformation uses prepared poses; instantiate with native deformation for mixer playback.',
      );
    }
    return AnimationMixer(
      nodes: {
        for (final e in _nodes.entries) animationNodeTarget(e.key): e.value,
      },
      morphTargets: {
        for (final e in morphTargets.entries)
          animationNodeTarget(e.key): e.value,
      },
    );
  }

  ModelInstance._(
    this._template,
    this._nodes,
    this._deformers,
    Map<int, List<Mesh>> morphTargets,
    this._nativeDeformation, {
    super.name,
  }) : morphTargets = Map.unmodifiable({
         for (final e in morphTargets.entries)
           e.key: List<Mesh>.unmodifiable(e.value),
       });
  void _validatePoseOwner(ModelPose pose) {
    if (!identical(pose._template, _template) ||
        pose.nodes.length != _nodes.length ||
        _nodes.keys.any((key) => !pose.nodes.containsKey(key))) {
      throw ArgumentError(
        'The sampled pose belongs to another model or scene.',
      );
    }
  }

  Map<int, Object3D> get nodes => Map.unmodifiable(_nodes);
  void _captureParents() {
    for (final node in _nodes.values) {
      _parents[node] = node.parent;
    }
    for (final node in _nodes.values) {
      for (final child in node.children.whereType<Mesh>()) {
        _parents[child] = child.parent;
        _geometries[child] = child.geometry;
      }
    }
  }

  /// Samples local transforms and morph weights without deforming geometry.
  /// With no animation, uses current transforms unless [initial] is true.
  /// Unspecified weights use the imported defaults. No events are emitted.
  ModelPose samplePose({
    bool initial = false,
    ModelAnimation? animation,
    Duration time = Duration.zero,
    Map<int, List<double>> morphWeights = const {},
  }) {
    if (animation != null &&
        !_template.animations.contains(animation) &&
        !animations.contains(animation)) {
      throw ArgumentError('Animation belongs to another model template.');
    }
    for (final entry in _parents.entries) {
      if (!identical(entry.key.parent, entry.value)) {
        throw StateError('Model nodes must retain their instance hierarchy.');
      }
    }
    final poses = <int, ({Vec3 position, Quat rotation, Vec3 scale})>{};
    final weights = <int, List<double>>{};
    for (final entry in _nodes.entries) {
      final authored = _template.nodes[entry.key], object = entry.value;
      final useCurrent = animation == null && !initial;
      poses[entry.key] = (
        position: useCurrent ? object.position : authored.position,
        rotation: useCurrent ? object.quaternion : authored.rotation,
        scale: useCurrent ? object.scale : authored.scale,
      );
    }
    for (final entry in _nodes.entries) {
      if (_template.nodes[entry.key].weights.isNotEmpty) {
        weights[entry.key] = _template.nodes[entry.key].weights;
      }
    }
    for (final channel
        in animation?.channels ?? const <ModelAnimationChannel>[]) {
      final old = poses[channel.node];
      if (old == null) continue;
      final value = channel.sample(time);
      Vec3 vector() => Vec3(value[0], value[1], value[2]);
      switch (channel.path) {
        case ModelAnimationPath.translation:
          poses[channel.node] = (
            position: vector(),
            rotation: old.rotation,
            scale: old.scale,
          );
        case ModelAnimationPath.rotation:
          poses[channel.node] = (
            position: old.position,
            rotation: Quat(value[0], value[1], value[2], value[3]),
            scale: old.scale,
          );
        case ModelAnimationPath.scale:
          poses[channel.node] = (
            position: old.position,
            rotation: old.rotation,
            scale: vector(),
          );
        case ModelAnimationPath.weights:
          weights[channel.node] = value;
      }
    }
    weights.addAll(morphWeights);
    return ModelPose._(_template, poses, weights);
  }

  /// Blends joint TRS and morph weights, then deforms the resulting pose once.
  void Function() prepareBlendedPose(
    Iterable<ModelPoseContribution> absolute, {
    Iterable<ModelPoseContribution> additive = const [],
  }) {
    final weighted = List<ModelPoseContribution>.of(absolute);
    final additions = List<ModelPoseContribution>.of(additive);
    for (final entry in [...weighted, ...additions]) {
      _validatePoseOwner(entry.pose);
      if (entry.reference case final reference?) _validatePoseOwner(reference);
    }
    return prepareSampledPose(_blendModelPoses(weighted, additions));
  }

  /// Prepares animation and deformation as one scene edit.
  void Function() preparePose({
    ModelAnimation? animation,
    Duration time = Duration.zero,
    Map<int, List<double>> morphWeights = const {},
  }) => prepareSampledPose(
    samplePose(animation: animation, time: time, morphWeights: morphWeights),
  );

  /// Validates an immutable pose before applying transforms or vertex updates.
  void Function() prepareSampledPose(ModelPose pose) {
    _validatePoseOwner(pose);
    for (final entry in _parents.entries) {
      if (!identical(entry.key.parent, entry.value)) {
        throw StateError('Model nodes must retain their instance hierarchy.');
      }
    }
    for (final entry in _geometries.entries) {
      if (!identical(entry.key.geometry, entry.value)) {
        throw StateError('Model geometry must retain its instance identity.');
      }
    }
    final poses = pose.nodes, weights = pose.weights;
    final worlds = <int, Mat4>{};
    final indices = Map<Object3D, int>.identity()
      ..addEntries(_nodes.entries.map((e) => MapEntry(e.value, e.key)));
    Mat4 world(int node) {
      if (worlds[node] case final cached?) return cached;
      final pose = poses[node];
      if (pose == null) {
        throw StateError('Skin joint is absent from the selected scene.');
      }
      if (!pose.position.isFinite ||
          !pose.scale.isFinite ||
          pose.scale.x == 0 ||
          pose.scale.y == 0 ||
          pose.scale.z == 0) {
        throw ArgumentError('Animation sampled a singular or nonfinite pose.');
      }
      final local = Mat4.compose(
        pose.position,
        pose.rotation.normalized(),
        pose.scale,
      );
      final parent = indices[_nodes[node]!.parent];
      return worlds[node] = parent == null ? local : world(parent) * local;
    }

    for (final node in poses.keys) {
      final matrix = world(node);
      if (_template.nodes[node].mesh != null) {
        final packed = Float32List.fromList(matrix.storage);
        if (packed.any((v) => !v.isFinite)) {
          throw ArgumentError(
            'Animated transform exceeds native float32 storage.',
          );
        }
        final determinant = Mat4(packed).toVectorMath().determinant();
        if (!determinant.isFinite ||
            determinant.abs() < 1e-20 ||
            determinant.abs() > 3.4028234663852886e38) {
          throw ArgumentError(
            'Animated transform cannot be inverted by the native renderer.',
          );
        }
      }
    }
    final edits = <void Function()>[];
    if (_nativeDeformation) {
      for (final entry in weights.entries) {
        final meshes = morphTargets[entry.key];
        if (meshes == null ||
            entry.value.length != _template.nodes[entry.key].weights.length ||
            entry.value.any((w) => !w.isFinite || w.abs() > 1e6)) {
          throw ArgumentError(
            'Morph weights must match the instance and remain finite.',
          );
        }
        for (final mesh in meshes) {
          if (mesh.morphWeights.length != entry.value.length) {
            throw StateError('Morph geometry must retain its instance layout.');
          }
          edits.add(() => mesh.morphWeights = entry.value);
        }
      }
    }
    for (final d in _deformers) {
      final source = d.source, deform = source.deformation!;
      final geometry = d.mesh.geometry;
      if (!geometry.isDynamic ||
          geometry.vertexCount != source.geometry.vertexCount ||
          !identical(d.geometry, geometry)) {
        throw StateError('Deformed geometry must retain its instance layout.');
      }
      final selected = weights[d.node] ?? const <double>[];
      if (selected.length != deform.morphPositions.length ||
          selected.any((w) => !w.isFinite)) {
        throw ArgumentError(
          'Morph weights must be finite and match target count.',
        );
      }
      final positions = Float32List.fromList(source.geometry.positions);
      final normals = Float32List.fromList(source.geometry.normals);
      final tangentAttribute =
          source.geometry.attributes[VertexSemantic.tangent];
      final tangents = tangentAttribute == null
          ? null
          : Float32List.fromList(tangentAttribute.data as Float32List);
      for (var t = 0; t < selected.length; t++) {
        for (var c = 0; c < positions.length; c++) {
          positions[c] += deform.morphPositions[t][c] * selected[t];
          normals[c] += deform.morphNormals[t][c] * selected[t];
        }
        if (tangents != null) {
          for (var v = 0; v < geometry.vertexCount; v++) {
            for (var c = 0; c < 3; c++) {
              tangents[v * 4 + c] +=
                  deform.morphTangents[t][v * 3 + c] * selected[t];
            }
          }
        }
      }
      if (deform.generatedNormals) {
        for (var vertex = 0; vertex < geometry.vertexCount; vertex += 3) {
          Vec3 point(int v) => Vec3(
            positions[v * 3],
            positions[v * 3 + 1],
            positions[v * 3 + 2],
          );
          final cross = (point(vertex + 1) - point(vertex)).cross(
            point(vertex + 2) - point(vertex),
          );
          final normal = cross.length2 == 0
              ? const Vec3(0, 0, 1)
              : cross.normalized();
          for (var v = vertex; v < vertex + 3; v++) {
            normals.setRange(v * 3, v * 3 + 3, [normal.x, normal.y, normal.z]);
          }
        }
      }
      List<Mat4>? palette;
      if (d.skin case final skinIndex?) {
        final skin = _template.skins[skinIndex];
        final inverse = world(d.node).inverted();
        palette = [
          for (var j = 0; j < skin.joints.length; j++)
            inverse * world(skin.joints[j]) * skin.inverseBindMatrices[j],
        ];
      }
      final influences = deform.joints.isEmpty
          ? 0
          : deform.joints.length ~/ geometry.vertexCount;
      for (var v = 0; v < geometry.vertexCount; v++) {
        Vec3 read(List<double> values, int size) =>
            Vec3(values[v * size], values[v * size + 1], values[v * size + 2]);
        var p = read(positions, 3), n = read(normals, 3);
        var tangent = tangents == null ? null : read(tangents, 4);
        if (palette != null) {
          final blend = List<double>.filled(16, 0);
          for (var j = 0; j < influences; j++) {
            final at = v * influences + j;
            final matrix = palette[deform.joints[at]].storage,
                weight = deform.weights[at];
            for (var c = 0; c < 16; c++) {
              blend[c] += matrix[c] * weight;
            }
          }
          final m = Mat4(blend), inverse = m.inverted().storage;
          Vec3 point(Vec3 p, bool translate) => Vec3(
            blend[0] * p.x +
                blend[4] * p.y +
                blend[8] * p.z +
                (translate ? blend[12] : 0),
            blend[1] * p.x +
                blend[5] * p.y +
                blend[9] * p.z +
                (translate ? blend[13] : 0),
            blend[2] * p.x +
                blend[6] * p.y +
                blend[10] * p.z +
                (translate ? blend[14] : 0),
          );
          p = point(p, true);
          n = Vec3(
            inverse[0] * n.x + inverse[1] * n.y + inverse[2] * n.z,
            inverse[4] * n.x + inverse[5] * n.y + inverse[6] * n.z,
            inverse[8] * n.x + inverse[9] * n.y + inverse[10] * n.z,
          );
          if (tangent != null) tangent = point(tangent, false);
        }
        n = n.normalized();
        positions.setRange(v * 3, v * 3 + 3, [p.x, p.y, p.z]);
        normals.setRange(v * 3, v * 3 + 3, [n.x, n.y, n.z]);
        if (tangent != null) {
          tangent = (tangent - n * n.dot(tangent)).normalized();
          tangents!.setRange(v * 4, v * 4 + 3, [
            tangent.x,
            tangent.y,
            tangent.z,
          ]);
        }
      }
      // Validate copied Float32 data before any node or geometry mutation.
      final updates = {
        VertexSemantic.position: VertexAttribute(
          positions,
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.normal: VertexAttribute(
          normals,
          format: VertexFormat.float32x3,
        ),
        if (tangents != null)
          VertexSemantic.tangent: VertexAttribute(
            tangents,
            format: VertexFormat.float32x4,
          ),
      };
      VertexLayout({...geometry.attributes, ...updates});
      edits.add(() {
        for (final entry in updates.entries) {
          geometry.updateAttribute(entry.key, entry.value.data);
        }
      });
    }
    return () => batch(() {
      for (final entry in poses.entries) {
        final node = _nodes[entry.key]!, pose = entry.value;
        node.position = pose.position;
        node.quaternion = pose.rotation;
        node.scale = pose.scale;
      }
      for (final edit in edits) {
        edit();
      }
    });
  }
}
