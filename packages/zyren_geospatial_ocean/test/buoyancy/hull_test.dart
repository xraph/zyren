import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

final boxVertices = [
  const Vec3(-1, -1, -1),
  const Vec3(1, -1, -1),
  const Vec3(1, 1, -1),
  const Vec3(-1, 1, -1),
  const Vec3(-1, -1, 1),
  const Vec3(1, -1, 1),
  const Vec3(1, 1, 1),
  const Vec3(-1, 1, 1),
];
final boxIndices = [
  0,
  2,
  1,
  0,
  3,
  2,
  4,
  5,
  6,
  4,
  6,
  7,
  0,
  1,
  5,
  0,
  5,
  4,
  3,
  7,
  6,
  3,
  6,
  2,
  0,
  4,
  7,
  0,
  7,
  3,
  1,
  2,
  6,
  1,
  6,
  5,
];
BuoyancyHull boxHull({int subdivisions = 0}) => BuoyancyHull(
  vertices: boxVertices,
  indices: boxIndices,
  subdivisions: subdivisions,
);
void main() {
  test('closed convex box partitions exactly and clips at the waterline', () {
    for (final depth in [0, 1, 3]) {
      final hull = boxHull(subdivisions: depth);
      expect(hull.volume, closeTo(8, 1e-12));
      for (final z in [-2.0, -1.0, -.25, 0.0, .5, 1.0, 2.0]) {
        final parts = hull.cells.map(
          (c) => c.clip(Vec3(0, 0, z), const Vec3(0, 0, 1)),
        );
        final volume = parts.fold(0.0, (v, c) => v + c.volume);
        expect(volume, closeTo(4 * (z + 1).clamp(0, 2), 1e-12));
        if (volume > 0) {
          final center =
              parts.fold(Vec3.zero, (v, c) => v + c.centroidOrZero * c.volume) /
              volume;
          expect(
            center.distanceTo(Vec3(0, 0, (z.clamp(-1, 1) - 1) / 2)),
            lessThan(1e-12),
          );
        }
      }
    }
  });
  test('sloping symmetric planes bisect a box', () {
    final hull = boxHull();
    for (final n in [
      const Vec3(1, 2, 3),
      const Vec3(-3, 1, 2),
      const Vec3(1, 1, 0),
    ]) {
      final volume = hull.cells.fold(
        0.0,
        (v, c) => v + c.clip(Vec3.zero, n.normalized()).volume,
      );
      expect(volume, closeTo(4, 1e-12));
    }
  });
  test('open, duplicate, inward, nonmanifold and nonconvex proxies fail', () {
    for (final indices in [
      boxIndices.sublist(3),
      [...boxIndices, ...boxIndices.take(3)],
      [boxIndices[1], boxIndices[0], ...boxIndices.skip(2)],
    ]) {
      expect(
        () => BuoyancyHull(vertices: boxVertices, indices: indices),
        throwsArgumentError,
      );
    }
    final concave = [...boxVertices]..[6] = Vec3.zero;
    expect(
      () => BuoyancyHull(vertices: concave, indices: boxIndices),
      throwsArgumentError,
    );
    expect(
      () => BuoyancyHull(
        vertices: [...boxVertices, boxVertices[0]],
        indices: boxIndices,
      ),
      throwsArgumentError,
    );
  });
}
