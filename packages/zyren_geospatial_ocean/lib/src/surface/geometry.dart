import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'cube_patch.dart';
import 'neighbours.dart';
import 'selector.dart';

/// Double-precision patch origin and native float32 local vertex data.
final class OceanPatchGeometry {
  final OceanPatchId id;
  final Vec3 origin;
  final BufferGeometry geometry;
  const OceanPatchGeometry(this.id, this.origin, this.geometry);
}

/// Complete stitched surface. Topology and sampling remain in double precision.
final class OceanSurfaceGeometry {
  final Ellipsoid ellipsoid;
  final int segments;
  final OceanPatchNeighbours topology;
  final _vertices = <(OceanPatchId, int, int), Vec3>{};
  final _patches = <OceanPatchId, OceanPatchGeometry>{};
  OceanSurfaceGeometry(
    Iterable<OceanPatchId> patches, {
    this.ellipsoid = Ellipsoid.wgs84,
    this.segments = 16,
    required int maxVertices,
  }) : topology = OceanPatchNeighbours(patches, ellipsoid: ellipsoid) {
    validateOceanEllipsoid(ellipsoid);
    validateOceanSegments(segments);
    validateOceanGeometryBudget(topology.patches.length, segments, maxVertices);
    // Validate balance before any vertex allocations.
    topology.sharedEdges;
  }
  int get vertexCount =>
      topology.patches.length * (segments + 1) * (segments + 1);
  List<OceanPatchGeometry> get patches =>
      List.unmodifiable(topology.patches.map(patch));
  OceanPatchGeometry patch(OceanPatchId id) {
    if (!topology.patches.contains(id)) {
      throw ArgumentError('Unknown ocean patch.');
    }
    return _patches.putIfAbsent(id, () {
      final origin = id.point(.5, .5, ellipsoid);
      return OceanPatchGeometry(
        id,
        origin,
        buildOceanPatchGeometry(
          id,
          segments,
          origin,
          (u, v) => sample(id, u, v),
          ellipsoid,
        ),
      );
    });
  }

  Vec3 sampleCube(Vec3 cube) {
    final id = topology.containing(cube), uv = id.localCoordinates(cube);
    return sample(id, uv.u.clamp(0, 1), uv.v.clamp(0, 1));
  }

  Vec3 sample(OceanPatchId patch, double u, double v) {
    if (!topology.patches.contains(patch)) {
      throw ArgumentError('Unknown ocean patch.');
    }
    return interpolateOceanGrid(segments, u, v, (i, j) => _vertex(patch, i, j));
  }

  Vec3 _vertex(
    OceanPatchId p,
    int i,
    int j,
  ) => _vertices.putIfAbsent((p, i, j), () {
    // Corners lie on every incident coarser grid because segments are dyadic >=4.
    if ((i == 0 || i == segments) && (j == 0 || j == segments)) {
      return p.point(i / segments, j / segments, ellipsoid);
    }
    final side = j == 0
        ? OceanPatchSide.south
        : i == segments
        ? OceanPatchSide.east
        : j == segments
        ? OceanPatchSide.north
        : i == 0
        ? OceanPatchSide.west
        : null;
    if (side != null) {
      final t = switch (side) {
        OceanPatchSide.south => i / segments,
        OceanPatchSide.east => j / segments,
        OceanPatchSide.north => 1 - i / segments,
        OceanPatchSide.west => 1 - j / segments,
      };
      final other = topology.across(p, side, t);
      if (other.level < p.level) {
        final uv = other.localCoordinates(
          p.cubePoint(i / segments, j / segments),
        );
        return sample(other, uv.u.clamp(0, 1), uv.v.clamp(0, 1));
      }
    }
    return p.point(i / segments, j / segments, ellipsoid);
  });
}

void validateOceanGeometryBudget(int count, int segments, int maxVertices) {
  if (maxVertices < 1 || maxVertices > 18000000) {
    throw ArgumentError('Invalid ocean vertex budget.');
  }
  if (count * (segments + 1) * (segments + 1) > maxVertices) {
    throw StateError('Ocean geometry exceeds its vertex budget.');
  }
}

/// Interpolates the actual [a,b,d], [a,d,c] triangles, including their diagonal.
Vec3 interpolateOceanGrid(
  int segments,
  double u,
  double v,
  Vec3 Function(int, int) vertex,
) {
  if (!u.isFinite || !v.isFinite || u < 0 || u > 1 || v < 0 || v > 1) {
    throw ArgumentError('Invalid ocean grid coordinate.');
  }
  final x = u * segments,
      y = v * segments,
      i = x.floor().clamp(0, segments - 1),
      j = y.floor().clamp(0, segments - 1);
  final tx = x - i, ty = y - j, a = vertex(i, j), d = vertex(i + 1, j + 1);
  return tx >= ty
      ? a * (1 - tx) + vertex(i + 1, j) * (tx - ty) + d * ty
      : a * (1 - ty) + d * tx + vertex(i, j + 1) * (ty - tx);
}

BufferGeometry buildOceanPatchGeometry(
  OceanPatchId id,
  int segments,
  Vec3 origin,
  Vec3 Function(double, double) sample,
  Ellipsoid ellipsoid, {
  Vec3 Function(double, double)? destination,
}) {
  final positions = <double>[],
      normals = <double>[],
      uv = <double>[],
      indices = <int>[],
      deltas = <double>[],
      normalDeltas = <double>[];
  void add(List<double> list, Vec3 p) => list.addAll([p.x, p.y, p.z]);
  for (var j = 0; j <= segments; j++) {
    for (var i = 0; i <= segments; i++) {
      final u = i / segments,
          v = j / segments,
          p = sample(u, v),
          normal = ellipsoid.surfaceNormal(p);
      add(positions, p - origin);
      add(normals, normal);
      uv.addAll([u, v]);
      if (destination != null) {
        final next = destination(u, v);
        add(deltas, next - p);
        add(normalDeltas, ellipsoid.surfaceNormal(next) - normal);
      }
    }
  }
  for (var j = 0; j < segments; j++) {
    for (var i = 0; i < segments; i++) {
      final a = j * (segments + 1) + i,
          b = a + 1,
          c = a + segments + 1,
          d = c + 1;
      indices.addAll([a, b, d, a, d, c]);
    }
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: indices,
    uv0: uv,
    morphTargets: [
      if (destination != null)
        MorphTarget(
          name: 'ocean-lod',
          positions: deltas,
          normals: normalDeltas,
        ),
    ],
  );
}
