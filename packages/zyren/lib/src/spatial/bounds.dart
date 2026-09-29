import 'dart:math' as math;
import '../math/mat4.dart';
import '../math/vec3.dart';

/// Immutable axis-aligned bounds. Empty bounds contain no points.
final class Bounds3 {
  final Vec3 minimum, maximum;
  final bool isEmpty;
  Bounds3(this.minimum, this.maximum) : isEmpty = false {
    if (!minimum.isFinite ||
        !maximum.isFinite ||
        minimum.x > maximum.x ||
        minimum.y > maximum.y ||
        minimum.z > maximum.z) {
      throw ArgumentError(
        'Bounds require finite, ordered minimum and maximum.',
      );
    }
  }
  const Bounds3.empty()
    : minimum = Vec3.zero,
      maximum = Vec3.zero,
      isEmpty = true;
  Vec3 get center => minimum * .5 + maximum * .5;
  Vec3 get size => maximum - minimum;
  List<Vec3> get corners => isEmpty
      ? const []
      : List.unmodifiable([
          for (final x in [minimum.x, maximum.x])
            for (final y in [minimum.y, maximum.y])
              for (final z in [minimum.z, maximum.z]) Vec3(x, y, z),
        ]);
  bool contains(Vec3 point) =>
      !isEmpty &&
      point.isFinite &&
      point.x >= minimum.x &&
      point.x <= maximum.x &&
      point.y >= minimum.y &&
      point.y <= maximum.y &&
      point.z >= minimum.z &&
      point.z <= maximum.z;
  Bounds3 union(Bounds3 other) {
    if (isEmpty) return other;
    if (other.isEmpty) return this;
    return Bounds3(
      Vec3(
        math.min(minimum.x, other.minimum.x),
        math.min(minimum.y, other.minimum.y),
        math.min(minimum.z, other.minimum.z),
      ),
      Vec3(
        math.max(maximum.x, other.maximum.x),
        math.max(maximum.y, other.maximum.y),
        math.max(maximum.z, other.maximum.z),
      ),
    );
  }

  Bounds3 transformed(Mat4 matrix) {
    final m = matrix.storage;
    if (m[3] != 0 || m[7] != 0 || m[11] != 0 || m[15] != 1) {
      throw ArgumentError('Bounds transformation requires an affine matrix.');
    }
    if (isEmpty) return this;
    var minX = double.infinity, minY = double.infinity, minZ = double.infinity;
    var maxX = double.negativeInfinity,
        maxY = double.negativeInfinity,
        maxZ = double.negativeInfinity;
    for (final p in corners) {
      final x = m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12];
      final y = m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13];
      final z = m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14];
      minX = math.min(minX, x);
      minY = math.min(minY, y);
      minZ = math.min(minZ, z);
      maxX = math.max(maxX, x);
      maxY = math.max(maxY, y);
      maxZ = math.max(maxZ, z);
    }
    return Bounds3(Vec3(minX, minY, minZ), Vec3(maxX, maxY, maxZ));
  }
}
