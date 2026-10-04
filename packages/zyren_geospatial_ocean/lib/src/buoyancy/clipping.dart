import 'dart:math' as math;
import 'package:zyren/zyren.dart';

final class BuoyancyVolume {
  final double volume;
  final Vec3? centroid;
  const BuoyancyVolume(this.volume, this.centroid);
  Vec3 get centroidOrZero => centroid ?? Vec3.zero;
}

/// A convex integration cell in metres. Winding does not affect its volume.
final class BuoyancyTetrahedron {
  final Vec3 a, b, c, d;
  BuoyancyTetrahedron(this.a, this.b, this.c, this.d) {
    if (vertices.any((v) => !v.isFinite) || !volume.isFinite || volume <= 0) {
      throw ArgumentError(
        'A buoyancy cell needs four finite noncoplanar vertices.',
      );
    }
  }
  List<Vec3> get vertices => [a, b, c, d];
  double get volume => ((b - a).dot((c - a).cross(d - a))).abs() / 6;
  Vec3 get centroid => a + ((b - a) + (c - a) + (d - a)) / 4;
  double get diameter {
    var result = 0.0;
    final v = vertices;
    for (var i = 0; i < 4; i++) {
      for (var j = i + 1; j < 4; j++) {
        result = math.max(result, v[i].distanceTo(v[j]));
      }
    }
    return result;
  }

  List<BuoyancyTetrahedron> bisect() {
    final v = vertices;
    var first = 0, second = 1;
    for (var i = 0; i < 4; i++) {
      for (var j = i + 1; j < 4; j++) {
        if (v[i].distanceTo(v[j]) > v[first].distanceTo(v[second])) {
          first = i;
          second = j;
        }
      }
    }
    final mid = v[first] + (v[second] - v[first]) / 2;
    final left = [...v]..[first] = mid, right = [...v]..[second] = mid;
    return [
      BuoyancyTetrahedron(left[0], left[1], left[2], left[3]),
      BuoyancyTetrahedron(right[0], right[1], right[2], right[3]),
    ];
  }

  /// Keep the half-space dot(position - surfacePoint, outwardNormal) <= 0.
  BuoyancyVolume clip(Vec3 surfacePoint, Vec3 outwardNormal) {
    if (!surfacePoint.isFinite ||
        !outwardNormal.isFinite ||
        (outwardNormal.length2 - 1).abs() > 1e-10) {
      throw ArgumentError(
        'A water plane needs a finite point and unit normal.',
      );
    }
    // Translate first so volume moments stay accurate in large world coordinates.
    final v = vertices.map((p) => p - a).toList();
    final plane = surfacePoint - a;
    final distance = v.map((p) => (p - plane).dot(outwardNormal)).toList();
    if (distance.every((s) => s <= 0)) return BuoyancyVolume(volume, centroid);
    if (distance.every((s) => s >= 0)) return const BuoyancyVolume(0, null);
    final polygons = <List<Vec3>>[], cap = <Vec3>[];
    final epsilon = diameter * 1e-13;
    void unique(List<Vec3> into, Vec3 p) {
      if (!into.any((q) => p.distanceTo(q) <= epsilon)) into.add(p);
    }

    for (final face in const [
      [0, 1, 2],
      [0, 3, 1],
      [0, 2, 3],
      [1, 3, 2],
    ]) {
      final clipped = <Vec3>[];
      for (var i = 0; i < 3; i++) {
        final j = face[i], k = face[(i + 1) % 3];
        final sj = distance[j], sk = distance[k];
        if (sj <= 0) unique(clipped, v[j]);
        if ((sj < 0 && sk > 0) || (sj > 0 && sk < 0)) {
          final p = v[j] + (v[k] - v[j]) * (sj / (sj - sk));
          unique(clipped, p);
          unique(cap, p);
        }
        if (sj == 0) unique(cap, v[j]);
      }
      if (clipped.length >= 3) polygons.add(clipped);
    }
    if (cap.length >= 3) {
      final center = cap.reduce((p, q) => p + q) / cap.length.toDouble();
      final u = (cap.first - center).normalized(), w = outwardNormal.cross(u);
      cap.sort(
        (p, q) => math
            .atan2((p - center).dot(w), (p - center).dot(u))
            .compareTo(math.atan2((q - center).dot(w), (q - center).dot(u))),
      );
      polygons.add(cap);
    }
    final points = <Vec3>[];
    for (final polygon in polygons) {
      for (final p in polygon) {
        unique(points, p);
      }
    }
    if (points.length < 4) return const BuoyancyVolume(0, null);
    final inside = points.reduce((p, q) => p + q) / points.length.toDouble();
    var total = 0.0;
    var moment = Vec3.zero;
    for (final polygon in polygons) {
      for (var i = 1; i < polygon.length - 1; i++) {
        final p = polygon[0], q = polygon[i], r = polygon[i + 1];
        final weight =
            (p - inside).dot((q - inside).cross(r - inside)).abs() / 6;
        total += weight;
        moment = moment + (inside + p + q + r) * (weight / 4);
      }
    }
    return total == 0
        ? const BuoyancyVolume(0, null)
        : BuoyancyVolume(total, a + moment / total);
  }
}
