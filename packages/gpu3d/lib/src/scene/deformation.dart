part of 'scene.dart';

mixin _MeshDeformation on Object3D {
  BufferGeometry get geometry;
  static int _nextLogicalId = 1;
  final int _deformationLogicalId = _nextLogicalId++;
  List<double>? _weights;
  DeformationSnapshot? _deformation;
  List<double> get morphWeights => _weights ??= List.unmodifiable(
    List<double>.filled(geometry.morphTargets.length, 0),
  );
  set morphWeights(List<double> values) {
    if (values.length != geometry.morphTargets.length ||
        values.any((v) => !v.isFinite || v.abs() > 1e6)) {
      throw ArgumentError(
        'Morph weights must match the targets and be finite within ±1000000.',
      );
    }
    if (List.generate(
      values.length,
      (i) => i,
    ).every((i) => values[i] == morphWeights[i])) {
      return;
    }
    _weights = List.unmodifiable(values);
    _changed();
  }

  void setMorphWeight(int index, double value) {
    RangeError.checkValidIndex(index, morphWeights, 'index');
    morphWeights = List<double>.of(morphWeights)..[index] = value;
  }

  DeformationSnapshot? captureDeformation() {
    final self = this;
    if (self is! SkinnedMesh && geometry.morphTargets.isEmpty) return null;
    final source = geometry.capture();
    final matrices = <Mat4>[];
    if (self is SkinnedMesh) {
      self._validateSkin(source);
      matrices.addAll(self.skin._capture(self));
    }
    final previous = _deformation;
    if (previous != null &&
        identical(previous.geometry, source) &&
        previous.weights.length == morphWeights.length &&
        previous.matrices.length == matrices.length &&
        List.generate(
          matrices.length,
          (i) => i,
        ).every((i) => matrices[i] == previous.matrices[i]) &&
        List.generate(
          morphWeights.length,
          (i) => i,
        ).every((i) => morphWeights[i] == previous.weights[i])) {
      return previous;
    }
    return _deformation = DeformationSnapshot._(
      _deformationLogicalId,
      source,
      morphWeights,
      matrices,
    );
  }

  /// Explicit CPU position query for picking and inspection. Rendering stays on the GPU.
  Vec3 vertexPosition(int index) {
    RangeError.checkValueInInterval(
      index,
      0,
      geometry.vertexCount - 1,
      'index',
    );
    return captureDeformation()?.vertexPosition(index) ??
        _position(geometry.positions, index);
  }

  Bounds3 get bounds =>
      captureDeformation()?.bounds ??
      Bounds3(
        geometry.capture().bounds.minimum,
        geometry.capture().bounds.maximum,
      );
}

/// Frozen mesh-local morph and joint state for one frame.
final class DeformationSnapshot {
  static int _nextId = 1;
  final int id = _nextId++;
  final int logicalId;
  final GeometrySnapshot geometry;
  final List<double> weights;
  final List<Mat4> matrices;
  DeformationSnapshot._(
    this.logicalId,
    this.geometry,
    List<double> weights,
    List<Mat4> matrices,
  ) : weights = List.unmodifiable(weights),
      matrices = List.unmodifiable(matrices);
  int get gpuByteLength => 272 + matrices.length * 64;
  Vec3 vertexPosition(int index) {
    RangeError.checkValueInInterval(
      index,
      0,
      geometry.layout.vertexCount - 1,
      'index',
    );
    var position = _position(geometry.positions, index);
    for (var i = 0; i < weights.length; i++) {
      final values = geometry.morphTargets[i].positions;
      if (values != null) {
        position = position + _position(values, index) * weights[i];
      }
    }
    if (matrices.isEmpty) return position;
    final jointIndices = geometry.joints!, jointWeights = geometry.weights!;
    var out = Vec3.zero, sum = 0.0;
    for (var c = 0; c < 4; c++) {
      final weight = jointWeights[index * 4 + c];
      if (weight == 0) continue;
      final m = matrices[jointIndices[index * 4 + c]].storage;
      out =
          out +
          Vec3(
                m[0] * position.x +
                    m[4] * position.y +
                    m[8] * position.z +
                    m[12],
                m[1] * position.x +
                    m[5] * position.y +
                    m[9] * position.z +
                    m[13],
                m[2] * position.x +
                    m[6] * position.y +
                    m[10] * position.z +
                    m[14],
              ) *
              weight;
      sum += weight;
    }
    return out * (1 / sum);
  }

  late final Bounds3 bounds = _bounds();
  Bounds3 _bounds() {
    var min = geometry.bounds.minimum, max = geometry.bounds.maximum;
    for (var i = 0; i < weights.length; i++) {
      final delta = geometry.morphTargets[i].positionBounds,
          weight = weights[i];
      min = min + (weight >= 0 ? delta.minimum : delta.maximum) * weight;
      max = max + (weight >= 0 ? delta.maximum : delta.minimum) * weight;
    }
    final local = Bounds3(min, max);
    if (matrices.isEmpty) return local;
    var result = const Bounds3.empty();
    for (final matrix in matrices) {
      result = result.union(local.transformed(matrix));
    }
    return result;
  }
}

Vec3 _position(List<double> values, int index) =>
    Vec3(values[index * 3], values[index * 3 + 1], values[index * 3 + 2]);
