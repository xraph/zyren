part of '../zyren_tools.dart';

/// Reasons a source cannot safely produce a solid section cap.
enum SectionCapIssue { topology, openOrNonManifold, nonConvex, complexity }

/// CPU cap result. Geometry is in world coordinates and has outward normals.
final class SectionCapResult {
  final List<BufferGeometry> geometries;
  final SectionCapIssue? issue;
  SectionCapResult._(List<BufferGeometry> geometries, [this.issue])
    : geometries = List.unmodifiable(geometries);
}

/// Caps one closed convex triangle solid against intersecting world half-spaces.
/// Coincident seam vertices are welded by exact position. Unsupported sources
/// return an issue and no geometry. Work is bounded to 4096 source triangles.
SectionCapResult buildSectionCaps(
  BufferGeometry source,
  Mat4 world,
  List<ClippingPlane> planes,
) {
  if (planes.length > 6) {
    throw ArgumentError('At most six planes are supported.');
  }
  SectionCapResult fail(SectionCapIssue issue) => SectionCapResult._([], issue);
  if (source.topology != GeometryTopology.triangles) {
    return fail(SectionCapIssue.topology);
  }
  if (source.indices.length > 4096 * 3 || source.vertexCount > 4096 * 3) {
    return fail(SectionCapIssue.complexity);
  }
  final vertices = <Vec3>[];
  final welded = <(double, double, double), int>{};
  final remap = <int>[];
  for (var i = 0; i < source.positions.length; i += 3) {
    final p = Vec3.array(source.positions, i);
    remap.add(
      welded.putIfAbsent((p.x, p.y, p.z), () {
        vertices.add(_point(world, p));
        return vertices.length - 1;
      }),
    );
  }
  if (vertices.any((p) => !p.isFinite)) return fail(SectionCapIssue.topology);
  final min = vertices.reduce(
    (a, b) => Vec3(math.min(a.x, b.x), math.min(a.y, b.y), math.min(a.z, b.z)),
  );
  final max = vertices.reduce(
    (a, b) => Vec3(math.max(a.x, b.x), math.max(a.y, b.y), math.max(a.z, b.z)),
  );
  final epsilon = (max - min).length * 1e-7;
  if (!epsilon.isFinite || epsilon == 0) return fail(SectionCapIssue.topology);
  final edges = <(int, int), List<int>>{};
  final triangles = <List<int>>[];
  for (var i = 0; i < source.indices.length; i += 3) {
    final t = [for (var j = 0; j < 3; j++) remap[source.indices[i + j]]];
    if (t.toSet().length != 3) return fail(SectionCapIssue.openOrNonManifold);
    final cross = (vertices[t[1]] - vertices[t[0]]).cross(
      vertices[t[2]] - vertices[t[0]],
    );
    if (cross.length <= epsilon * epsilon) {
      return fail(SectionCapIssue.topology);
    }
    final normal = cross.normalized();
    var positive = false, negative = false;
    for (final v in vertices) {
      final d = normal.dot(v - vertices[t[0]]);
      positive |= d > epsilon;
      negative |= d < -epsilon;
    }
    if (positive && negative) return fail(SectionCapIssue.nonConvex);
    final index = triangles.length;
    triangles.add(t);
    for (var j = 0; j < 3; j++) {
      final a = t[j], b = t[(j + 1) % 3];
      edges.putIfAbsent((math.min(a, b), math.max(a, b)), () => []).add(index);
    }
  }
  if (edges.values.any((faces) => faces.length != 2)) {
    return fail(SectionCapIssue.openOrNonManifold);
  }
  // Reject disconnected shells, including coincident duplicated solids.
  final adjacency = List.generate(triangles.length, (_) => <int>[]);
  for (final faces in edges.values) {
    adjacency[faces[0]].add(faces[1]);
    adjacency[faces[1]].add(faces[0]);
  }
  final visited = <int>{}, pending = [0];
  while (pending.isNotEmpty) {
    final face = pending.removeLast();
    if (visited.add(face)) pending.addAll(adjacency[face]);
  }
  if (visited.length != triangles.length) {
    return fail(SectionCapIssue.openOrNonManifold);
  }
  final caps = <BufferGeometry>[];
  for (var planeIndex = 0; planeIndex < planes.length; planeIndex++) {
    final plane = planes[planeIndex];
    final distances = vertices.map(plane.distanceTo).toList();
    // A tangent plane does not expose an interior cross section.
    if (!distances.any((d) => d < -epsilon) ||
        !distances.any((d) => d > epsilon)) {
      continue;
    }
    final points = <Vec3>[];
    void add(Vec3 p) {
      if (!points.any((v) => v.distanceTo(p) <= epsilon)) points.add(p);
    }

    for (final edge in edges.keys) {
      final a = edge.$1, b = edge.$2, da = distances[a], db = distances[b];
      if (da.abs() <= epsilon) add(vertices[a]);
      if (db.abs() <= epsilon) add(vertices[b]);
      if (da * db < 0) {
        add(vertices[a] + (vertices[b] - vertices[a]) * (da / (da - db)));
      }
    }
    if (points.length < 3) continue;
    final center = points.reduce((a, b) => a + b) / points.length.toDouble();
    final normal = -plane.normal;
    final helper = normal.x.abs() < .9
        ? const Vec3(1, 0, 0)
        : const Vec3(0, 1, 0);
    final u = normal.cross(helper).normalized(), v = normal.cross(u);
    points.sort(
      (a, b) => math
          .atan2((a - center).dot(v), (a - center).dot(u))
          .compareTo(math.atan2((b - center).dot(v), (b - center).dot(u))),
    );
    var polygon = points;
    for (var j = 0; j < planes.length; j++) {
      if (j == planeIndex || polygon.isEmpty) continue;
      final other = planes[j], clipped = <Vec3>[];
      for (var k = 0; k < polygon.length; k++) {
        final a = polygon[k], b = polygon[(k + 1) % polygon.length];
        final da = other.distanceTo(a), db = other.distanceTo(b);
        if (da >= 0) clipped.add(a);
        if ((da >= 0) != (db >= 0)) clipped.add(a + (b - a) * (da / (da - db)));
      }
      polygon = clipped;
    }
    if (polygon.length < 3) continue;
    final positions = <double>[], normals = <double>[], indices = <int>[];
    for (var j = 1; j + 1 < polygon.length; j++) {
      final a = polygon[0], b = polygon[j], c = polygon[j + 1];
      if ((b - a).cross(c - a).length <= epsilon * epsilon) continue;
      for (final p in [a, b, c]) {
        indices.add(indices.length);
        positions.addAll(p.storage);
        normals.addAll(normal.storage);
      }
    }
    if (indices.isNotEmpty) {
      caps.add(
        BufferGeometry(
          positions: positions,
          normals: normals,
          indices: indices,
        ),
      );
    }
  }
  return SectionCapResult._(caps);
}
