import 'package:zyren/zyren.dart';
import 'cube_patch.dart';
import 'coverage.dart';
import 'geometry.dart';

/// Holds the common refinement until a transition completes, including coarsening.
/// Set each mesh's sole morph weight to the same fraction in [0,1].
final class OceanSurfaceMorph {
  final OceanSurfaceGeometry from, to;
  late final List<OceanPatchGeometry> patches;
  late final Set<OceanPatchId> _ids;
  OceanSurfaceMorph(this.from, this.to, {required int maxVertices}) {
    if (from.segments != to.segments ||
        from.ellipsoid.x != to.ellipsoid.x ||
        from.ellipsoid.y != to.ellipsoid.y ||
        from.ellipsoid.z != to.ellipsoid.z) {
      throw ArgumentError(
        'Ocean morph endpoints require matching grids and ellipsoids.',
      );
    }
    final common = {...from.topology.patches, ...to.topology.patches};
    for (final p in common.toList()) {
      for (
        var ancestor = p.parent;
        ancestor != null;
        ancestor = ancestor.parent
      ) {
        common.remove(ancestor);
      }
    }
    OceanPatchCoverage(common);
    validateOceanGeometryBudget(common.length, from.segments, maxVertices);
    _ids = Set.unmodifiable(common);
    patches = List.unmodifiable(
      common.map((id) {
        final origin = id.point(.5, .5, from.ellipsoid);
        return OceanPatchGeometry(
          id,
          origin,
          buildOceanPatchGeometry(
            id,
            from.segments,
            origin,
            (u, v) => from.sampleCube(id.cubePoint(u, v)),
            from.ellipsoid,
            destination: (u, v) => to.sampleCube(id.cubePoint(u, v)),
          ),
        );
      }),
    );
  }
  int get vertexCount =>
      patches.length * (from.segments + 1) * (from.segments + 1);
  Vec3 sample(OceanPatchId id, double u, double v, double fraction) {
    if (!_ids.contains(id) ||
        !fraction.isFinite ||
        fraction < 0 ||
        fraction > 1) {
      throw ArgumentError('Invalid ocean morph patch or fraction.');
    }
    return interpolateOceanGrid(from.segments, u, v, (i, j) {
      final cube = id.cubePoint(i / from.segments, j / from.segments);
      return from.sampleCube(cube) * (1 - fraction) +
          to.sampleCube(cube) * fraction;
    });
  }
}
