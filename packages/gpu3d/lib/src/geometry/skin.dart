part of '../scene/scene.dart';

class Bone extends Object3D {
  Bone({super.name});
}

/// Ordered joints and transforms from mesh bind coordinates to joint coordinates.
/// Joint objects belong to a model instance; inverse binds are immutable.
final class Skin {
  final List<Object3D> joints;
  final List<Mat4> inverseBindMatrices;
  Skin({
    required List<Object3D> joints,
    required List<Mat4> inverseBindMatrices,
  }) : joints = _joints(joints),
       inverseBindMatrices = _binds(inverseBindMatrices) {
    if (joints.length != inverseBindMatrices.length) {
      throw ArgumentError('Each skin joint needs an inverse bind matrix.');
    }
  }
  factory Skin.fromBindPose({
    required List<Object3D> joints,
    Mat4? meshBindMatrix,
  }) {
    final checked = _joints(joints), bind = meshBindMatrix ?? Mat4.identity();
    _affine(bind);
    return Skin(
      joints: checked,
      inverseBindMatrices: [
        for (final joint in checked) joint.worldMatrix.inverted() * bind,
      ],
    );
  }
  static List<Object3D> _joints(List<Object3D> values) {
    if (values.isEmpty ||
        values.length > 256 ||
        (Set<Object3D>.identity()..addAll(values)).length != values.length) {
      throw ArgumentError('A skin needs 1..256 distinct joints.');
    }
    return List.unmodifiable(values);
  }

  static List<Mat4> _binds(List<Mat4> values) {
    if (values.isEmpty || values.length > 256) {
      throw ArgumentError('A skin needs 1..256 inverse bind matrices.');
    }
    for (final matrix in values) {
      _affine(matrix);
    }
    return List.unmodifiable(values);
  }

  static void _affine(Mat4 matrix) {
    final m = matrix.storage;
    if (m[3] != 0 || m[7] != 0 || m[11] != 0 || m[15] != 1) {
      throw ArgumentError('Skin transforms must be affine.');
    }
    matrix.inverted();
  }

  List<Mat4> _capture(Object3D mesh) {
    final ancestors = <Object3D, Mat4>{};
    var transform = Mat4.identity();
    Object3D? node = mesh;
    while (node != null) {
      ancestors[node] = transform;
      transform = node.localMatrix * transform;
      node = node.parent;
    }
    final meshWorld = transform;
    return [
      for (var i = 0; i < joints.length; i++)
        _relativeJoint(joints[i], ancestors, meshWorld) *
            inverseBindMatrices[i],
    ];
  }

  static Mat4 _relativeJoint(
    Object3D joint,
    Map<Object3D, Mat4> ancestors,
    Mat4 meshWorld,
  ) {
    var transform = Mat4.identity();
    Object3D? node = joint;
    while (node != null) {
      if (ancestors[node] case final meshToAncestor?) {
        return meshToAncestor.inverted() * transform;
      }
      transform = node.localMatrix * transform;
      node = node.parent;
    }
    return meshWorld.inverted() * transform;
  }
}

class SkinnedMesh extends Mesh {
  final Skin skin;
  GeometrySnapshot? _validatedSkin;
  SkinnedMesh(
    super.geometry,
    super.material, {
    required this.skin,
    super.name,
    super.renderOrder,
  }) {
    if (geometry.topology != GeometryTopology.triangles) {
      throw ArgumentError('SkinnedMesh requires triangle geometry.');
    }
    _validateSkin(geometry.capture());
  }
  void _validateSkin(GeometrySnapshot geometry) {
    if (identical(_validatedSkin, geometry)) return;
    final indices = geometry.joints;
    if (indices == null ||
        geometry.weights == null ||
        indices.any((i) => i >= skin.joints.length)) {
      throw ArgumentError(
        'Skinned geometry needs joint/weight attributes with valid joint indices.',
      );
    }
    _validatedSkin = geometry;
  }
}
