import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test('all cube face seams and corners share exact ellipsoid coverage', () {
    for (final ellipsoid in [Ellipsoid.wgs84, Ellipsoid(3, 2, 1)]) {
      final roots = [
        for (var face = 0; face < 6; face++)
          OceanPatchId(face: face, level: 0, x: 0, y: 0),
      ];
      final topology = OceanPatchNeighbours(roots, ellipsoid: ellipsoid);
      final edges = topology.sharedEdges;
      expect(edges, hasLength(12));
      for (final pair in edges) {
        for (final t in [0.0, .25, .5, .75, 1.0]) {
          expect(
            pair.first.point(t).distanceTo(pair.second.point(1 - t)),
            lessThan(1e-6),
          );
        }
      }
      for (final patch in roots) {
        for (final (u, v) in [(0.0, 0.0), (1.0, 0.0), (1.0, 1.0), (0.0, 1.0)]) {
          final p = patch.point(u, v, ellipsoid);
          expect(
            p.x * p.x / (ellipsoid.x * ellipsoid.x) +
                p.y * p.y / (ellipsoid.y * ellipsoid.y) +
                p.z * p.z / (ellipsoid.z * ellipsoid.z),
            closeTo(1, 1e-12),
          );
        }
      }
    }
  });
  test('coarse/fine edge segments have matching reversed parameterization', () {
    final roots = [
      for (var f = 0; f < 6; f++) OceanPatchId(face: f, level: 0, x: 0, y: 0),
    ];
    final patches = [...roots.skip(1), ...roots.first.children];
    expect(OceanPatchCoverage(patches).complete, isTrue);
    for (final edge in OceanPatchNeighbours(patches).sharedEdges) {
      for (final t in [0.0, .5, 1.0]) {
        expect(
          edge.first.point(t).distanceTo(edge.second.point(1 - t)),
          lessThan(1e-6),
        );
      }
    }
    expect(() => OceanPatchCoverage(patches.skip(1)), throwsArgumentError);
    expect(
      () => OceanPatchCoverage([...patches, roots.first]),
      throwsArgumentError,
    );
  });
}
