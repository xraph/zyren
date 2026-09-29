import 'dart:typed_data';
import '../math/vec3.dart';
import '../spatial/bounds.dart';

/// Immutable mesh-local deltas. Tangent handedness is never displaced.
final class MorphTarget {
  final String? name;
  final Float32List? positions, normals, tangents;
  late final int vertexCount;
  MorphTarget({
    this.name,
    List<double>? positions,
    List<double>? normals,
    List<double>? tangents,
  }) : positions = _copy(positions),
       normals = _copy(normals),
       tangents = _copy(tangents) {
    final attributes = [?this.positions, ?this.normals, ?this.tangents];
    if (attributes.isEmpty) {
      throw ArgumentError('A morph target needs at least one delta attribute.');
    }
    vertexCount = attributes.first.length ~/ 3;
    if (attributes.any((a) => a.length != vertexCount * 3)) {
      throw ArgumentError('Morph attribute counts must match.');
    }
  }
  static Float32List? _copy(List<double>? values) {
    if (values == null) return null;
    if (values.isEmpty ||
        values.length > 3000000 ||
        values.length % 3 != 0 ||
        values.any((v) => !v.isFinite)) {
      throw ArgumentError('Morph deltas need 1..1000000 finite vec3 values.');
    }
    final copy = Float32List.fromList(values);
    if (copy.any((v) => !v.isFinite)) {
      throw ArgumentError('Morph deltas must fit finite float32 storage.');
    }
    return copy.asUnmodifiableView();
  }

  int get byteLength =>
      (positions?.lengthInBytes ?? 0) +
      (normals?.lengthInBytes ?? 0) +
      (tangents?.lengthInBytes ?? 0);
  late final Bounds3 positionBounds = _bounds();
  Bounds3 _bounds() {
    final values = positions;
    if (values == null) return Bounds3(Vec3.zero, Vec3.zero);
    var min = Vec3(values[0], values[1], values[2]), max = min;
    for (var i = 3; i < values.length; i += 3) {
      final p = Vec3(values[i], values[i + 1], values[i + 2]);
      min = Vec3(
        p.x < min.x ? p.x : min.x,
        p.y < min.y ? p.y : min.y,
        p.z < min.z ? p.z : min.z,
      );
      max = Vec3(
        p.x > max.x ? p.x : max.x,
        p.y > max.y ? p.y : max.y,
        p.z > max.z ? p.z : max.z,
      );
    }
    return Bounds3(min, max);
  }
}
