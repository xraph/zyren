import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

List<OceanPatchId> roots() => [
  for (var f = 0; f < 6; f++) OceanPatchId(face: f, level: 0, x: 0, y: 0),
];
void main() {
  test(
    'stitched mesh edges agree between vertices, including across cube faces',
    () {
      final r = roots(),
          mesh = OceanSurfaceGeometry(
            [...r.skip(1), ...r.first.children],
            segments: 8,
            maxVertices: 10000,
          );
      for (final edge in mesh.topology.sharedEdges) {
        for (var i = 0; i <= 32; i++) {
          final t = i / 32,
              a = oceanEdgeUv(
                edge.first.side,
                edge.first.start + (edge.first.end - edge.first.start) * t,
              ),
              b = oceanEdgeUv(
                edge.second.side,
                edge.second.start +
                    (edge.second.end - edge.second.start) * (1 - t),
              );
          expect(
            mesh
                .sample(edge.first.patch, a.u, a.v)
                .distanceTo(mesh.sample(edge.second.patch, b.u, b.v)),
            lessThan(1e-6),
          );
        }
      }
      final p = r.first.children.first, at = mesh.sample(p, .37, .69);
      expect(at.isFinite, isTrue);
      final g = mesh.patch(p);
      expect(g.geometry.vertexCount, 81);
      expect(g.geometry.indices.length, 8 * 8 * 6);
      // The fine boundary midpoint follows a coarse segment chord, below the exact ellipsoid.
      final fine = mesh.topology.sharedEdges.firstWhere(
        (e) => e.first.patch.level > e.second.patch.level,
      );
      final uv = oceanEdgeUv(fine.first.side, 1 / 8);
      expect(
        mesh
            .sample(fine.first.patch, uv.u, uv.v)
            .distanceTo(fine.first.point(1 / 8)),
        greaterThan(100),
      );
    },
  );
  test(
    'common refinement morphs both refinement and coarsening without boundary cracks',
    () {
      final r = roots();
      final a = OceanSurfaceGeometry(
        [...r.skip(1), ...r[0].children],
        segments: 8,
        maxVertices: 10000,
      );
      final b = OceanSurfaceGeometry(
        [r[0], ...r.skip(2), ...r[1].children],
        segments: 8,
        maxVertices: 10000,
      );
      expect(
        () => OceanSurfaceMorph(a, b, maxVertices: 9 * 81),
        throwsStateError,
      );
      final morph = OceanSurfaceMorph(a, b, maxVertices: 10000);
      expect(morph.patches.length, 12);
      final topology = OceanPatchNeighbours(morph.patches.map((p) => p.id));
      for (final edge in topology.sharedEdges) {
        for (final amount in [0.0, .25, .5, .75, 1.0]) {
          for (var i = 0; i <= 16; i++) {
            final t = i / 16,
                uv = oceanEdgeUv(edge.first.side, t),
                cube = edge.first.patch.cubePoint(uv.u, uv.v);
            final expected =
                a.sampleCube(cube) * (1 - amount) + b.sampleCube(cube) * amount;
            expect(
              morph
                  .sample(edge.first.patch, uv.u, uv.v, amount)
                  .distanceTo(expected),
              lessThan(1e-6),
            );
            final uv2 = oceanEdgeUv(
              edge.second.side,
              edge.second.start +
                  (edge.second.end - edge.second.start) * (1 - t),
            );
            expect(
              morph
                  .sample(edge.second.patch, uv2.u, uv2.v, amount)
                  .distanceTo(expected),
              lessThan(1e-6),
            );
          }
        }
      }
      final patch = morph.patches.first;
      final mesh = Mesh(patch.geometry, UnlitMaterial())..morphWeights = [.5];
      final rendered = mesh.vertexPosition(10) + patch.origin;
      expect(
        rendered.distanceTo(morph.sample(patch.id, 1 / 8, 1 / 8, .5)),
        lessThan(.5),
      );
    },
  );
}
