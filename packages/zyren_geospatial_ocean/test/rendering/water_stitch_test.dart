import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test(
    'displaced control stencils stay stitched through refinement and coarsening',
    () {
      final roots = [
        for (var f = 0; f < 6; f++) OceanPatchId(face: f, level: 0, x: 0, y: 0),
      ];
      final a = OceanSurfaceGeometry(
        [...roots.skip(1), ...roots[0].children],
        segments: 8,
        maxVertices: 10000,
      );
      final b = OceanSurfaceGeometry(
        [roots[0], ...roots.skip(2), ...roots[1].children],
        segments: 8,
        maxVertices: 10000,
      );
      final morph = OceanSurfaceMorph(a, b, maxVertices: 10000);
      final controls = OceanWaterGeometry.fromMorph(morph);
      final neighbours = OceanPatchNeighbours(morph.patches.map((p) => p.id));
      Vec3 displacement(Vec3 p, double footprint) =>
          Vec3(
            math.sin(p.y / 10000) * 20,
            math.sin(p.z / 6000) * 10,
            math.cos(p.x / 7000) * 30,
          ) /
          (1 + footprint / 1e6);
      for (final fraction in [0.0, .3, .7, 1.0]) {
        for (final edge in neighbours.sharedEdges) {
          for (var i = 0; i <= 32; i++) {
            final t = i / 32;
            final u = oceanEdgeUv(
              edge.first.side,
              edge.first.start + (edge.first.end - edge.first.start) * t,
            );
            final v = oceanEdgeUv(
              edge.second.side,
              edge.second.start +
                  (edge.second.end - edge.second.start) * (1 - t),
            );
            final first = controls.patch(edge.first.patch),
                second = controls.patch(edge.second.patch);
            expect(
              first
                  .sample(u.u, u.v, fraction, displacement)
                  .distanceTo(second.sample(v.u, v.v, fraction, displacement)),
              lessThan(2e-6),
            );
            expect(
              first
                  .sample(u.u, u.v, fraction, (_, _) => Vec3.zero)
                  .distanceTo(
                    morph.sample(edge.first.patch, u.u, u.v, fraction),
                  ),
              lessThan(2e-6),
            );
          }
        }
      }
    },
  );
}
