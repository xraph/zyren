part of 'scene.dart';

/// Shared geometry and material with fixed, stable picking slots.
/// Transforms are local to this object. Each view sorts its own GPU instances.
class InstancedMesh extends Mesh {
  final List<Mat4> _transforms;
  int get count => _transforms.length;
  InstancedMesh(
    super.geometry,
    super.material, {
    required int count,
    super.name,
    super.renderOrder,
  }) : _transforms = List.filled(
         RangeError.checkValueInInterval(count, 1, 65536, 'count'),
         Mat4.identity(),
       );

  Mat4 transformAt(int index) => _transforms[index];

  void setTransform(int index, Mat4 transform) {
    RangeError.checkValidIndex(index, _transforms);
    final m = transform.storage;
    final determinant = transform.toVectorMath().determinant();
    if (m[3] != 0 ||
        m[7] != 0 ||
        m[11] != 0 ||
        m[15] != 1 ||
        !determinant.isFinite ||
        determinant.abs() < 1e-20) {
      throw ArgumentError(
        'Instances require finite, invertible affine transforms.',
      );
    }
    if (_transforms[index] == transform) return;
    _transforms[index] = transform;
    _changed();
  }

  @override
  void _validateMaterial(MeshMaterial material) {
    super._validateMaterial(material);
    if (geometry.topology != GeometryTopology.triangles ||
        material is ShaderMaterial) {
      throw UnsupportedError(
        'Instances require triangles with a built-in material.',
      );
    }
  }
}
