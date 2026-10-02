import 'dart:math' as math;
import '../materials/material.dart' show MaterialSide;
import '../math/vec3.dart';
import 'bounds.dart';

/// A finite origin and unit direction. Distances are in the ray's coordinates.
final class Ray {
  final Vec3 origin, direction;
  Ray(this.origin, Vec3 direction) : direction = direction.normalized() {
    if (!origin.isFinite) throw ArgumentError('Ray origin must be finite.');
  }

  Vec3 at(double distance) {
    final point = origin + direction * distance;
    if (!distance.isFinite || !point.isFinite) {
      throw ArgumentError('Ray distance and point must be finite.');
    }
    return point;
  }

  /// Entry distance, or zero if the origin is inside or on the box.
  double? intersectBounds(Bounds3 bounds) {
    if (bounds.isEmpty) return null;
    var entry = 0.0, exit = double.infinity;
    for (final (o, d, low, high) in [
      (origin.x, direction.x, bounds.minimum.x, bounds.maximum.x),
      (origin.y, direction.y, bounds.minimum.y, bounds.maximum.y),
      (origin.z, direction.z, bounds.minimum.z, bounds.maximum.z),
    ]) {
      if (d == 0) {
        if (o < low || o > high) return null;
        continue;
      }
      final a = (low - o) / d, b = (high - o) / d;
      entry = math.max(entry, math.min(a, b));
      exit = math.min(exit, math.max(a, b));
      if (entry > exit) return null;
    }
    return entry.isFinite ? entry : null;
  }

  /// Indexed winding defines the front face. Edges and vertices are included.
  RayTriangleHit? intersectTriangle(
    Vec3 a,
    Vec3 b,
    Vec3 c, {
    MaterialSide side = MaterialSide.doubleSided,
  }) {
    if (!a.isFinite || !b.isFinite || !c.isFinite) {
      throw ArgumentError('Triangle vertices must be finite.');
    }
    final ab = b - a, ac = c - a, p = direction.cross(ac);
    final determinant = ab.dot(p);
    if (!determinant.isFinite ||
        determinant == 0 ||
        (side == MaterialSide.front && determinant < 0) ||
        (side == MaterialSide.back && determinant > 0)) {
      return null;
    }
    final offset = origin - a, q = offset.cross(ab);
    final u = offset.dot(p) / determinant, v = direction.dot(q) / determinant;
    if (!u.isFinite || !v.isFinite || u < 0 || v < 0 || u + v > 1) return null;
    final distance = ac.dot(q) / determinant;
    if (!distance.isFinite || distance < 0) return null;
    return RayTriangleHit._(at(distance), distance, Vec3(1 - u - v, u, v));
  }
}

final class RayTriangleHit {
  final Vec3 point, barycentric;
  final double distance;
  const RayTriangleHit._(this.point, this.distance, this.barycentric);
}
