part of '../zyren_tools.dart';

/// Reasons a source cannot safely produce a solid section cap.
/// [nonConvex] is retained for compatibility; concave solids are supported.
enum SectionCapIssue { topology, openOrNonManifold, nonConvex, complexity }

/// CPU cap result. Geometry is in world coordinates and has outward normals.
final class SectionCapResult {
  final List<BufferGeometry> geometries;
  final SectionCapIssue? issue;
  SectionCapResult._(List<BufferGeometry> geometries, [this.issue])
    : geometries = List.unmodifiable(geometries);
}

/// Caps closed triangle shells, including concavities and nested cavities.
/// Exact coincident seam vertices are welded. Open, non-manifold or ambiguous
/// intersections return an issue with no partial result. Output is float32;
/// rebase the transform and planes before using distant world coordinates.
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
  if (source.indices.length > 100000 * 3 || source.vertexCount > 300000) {
    return fail(SectionCapIssue.complexity);
  }
  final vertices = <Vec3>[], remap = <int>[];
  final welded = <(double, double, double), int>{};
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
  final epsilon = (max - min).length * 1e-8;
  if (!epsilon.isFinite || epsilon == 0) return fail(SectionCapIssue.topology);
  final parents = List.generate(vertices.length, (i) => i);
  int root(int index) {
    var result = index;
    while (parents[result] != result) {
      result = parents[result];
    }
    while (parents[index] != index) {
      final next = parents[index];
      parents[index] = result;
      index = next;
    }
    return result;
  }

  final edges = <(int, int), int>{};
  final triangles = <List<int>>[];
  for (var i = 0; i < source.indices.length; i += 3) {
    final t = [for (var j = 0; j < 3; j++) remap[source.indices[i + j]]];
    if (t.toSet().length != 3) return fail(SectionCapIssue.openOrNonManifold);
    if ((vertices[t[1]] - vertices[t[0]])
            .cross(vertices[t[2]] - vertices[t[0]])
            .length <=
        epsilon * epsilon) {
      return fail(SectionCapIssue.topology);
    }
    triangles.add(t);
    for (var j = 0; j < 3; j++) {
      final a = t[j], b = t[(j + 1) % 3];
      parents[root(a)] = root(b);
      final key = (math.min(a, b), math.max(a, b));
      edges.update(key, (n) => n + 1, ifAbsent: () => 1);
    }
  }
  if (edges.values.any((count) => count != 2)) {
    return fail(SectionCapIssue.openOrNonManifold);
  }
  for (var i = 0; i < planes.length; i++) {
    for (var j = i + 1; j < planes.length; j++) {
      if (planes[i].normal == -planes[j].normal &&
          planes[i].offset + planes[j].offset >= 0) {
        return SectionCapResult._([]);
      }
    }
  }
  final caps = <BufferGeometry>[];
  for (var planeIndex = 0; planeIndex < planes.length; planeIndex++) {
    final plane = planes[planeIndex];
    if (planes
        .take(planeIndex)
        .any((p) => p.normal == plane.normal && p.offset == plane.offset)) {
      continue;
    }
    final distances = vertices.map(plane.distanceTo).toList();
    if (!distances.any((d) => d < -epsilon) ||
        !distances.any((d) => d > epsilon)) {
      continue;
    }
    final shellCuts = <int, int>{};
    for (var i = 0; i < vertices.length; i++) {
      final side = distances[i] < -epsilon
          ? 1
          : distances[i] > epsilon
          ? 2
          : 0;
      shellCuts.update(root(i), (flags) => flags | side, ifAbsent: () => side);
    }
    final points = <Vec3>[];
    final pointKeys = <(int, int), int>{};
    final segments = <(int, int)>{};
    int vertexPoint(int a) => pointKeys.putIfAbsent((a, a), () {
      points.add(vertices[a] - plane.normal * distances[a]);
      return points.length - 1;
    });
    int edgePoint(int a, int b) =>
        pointKeys.putIfAbsent((math.min(a, b), math.max(a, b)), () {
          final da = distances[a], db = distances[b];
          points.add(
            vertices[a] + (vertices[b] - vertices[a]) * (da / (da - db)),
          );
          return points.length - 1;
        });
    for (final t in triangles) {
      if (shellCuts[root(t.first)] != 3) continue;
      final hit = <int>{};
      // Fully coplanar faces are an existing surface, not an exposed interior.
      if (t.every((a) => distances[a].abs() <= epsilon)) continue;
      for (var j = 0; j < 3; j++) {
        final a = t[j],
            b = t[(j + 1) % 3],
            da = distances[a],
            db = distances[b];
        if (da.abs() <= epsilon) hit.add(vertexPoint(a));
        if (da.abs() > epsilon && db.abs() > epsilon && (da < 0) != (db < 0)) {
          hit.add(edgePoint(a, b));
        }
      }
      if (hit.length == 2) {
        final a = hit.first, b = hit.last;
        if (points[a].distanceTo(points[b]) > epsilon) {
          segments.add((math.min(a, b), math.max(a, b)));
        }
      } else if (hit.length > 2) {
        return fail(SectionCapIssue.topology);
      }
    }
    if (segments.isEmpty) continue;
    final degrees = List.filled(points.length, 0);
    for (final s in segments) {
      degrees[s.$1]++;
      degrees[s.$2]++;
    }
    if (degrees.any((n) => n != 0 && n != 2)) {
      return fail(SectionCapIssue.topology);
    }
    final normal = -plane.normal;
    final helper = normal.x.abs() < .9
        ? const Vec3(1, 0, 0)
        : const Vec3(0, 1, 0);
    final u = normal.cross(helper).normalized(), v = normal.cross(u);
    final origin = points.first;
    final xy = [
      for (final p in points) ((p - origin).dot(u), (p - origin).dot(v)),
    ];
    final levels = xy.map((p) => p.$2).toSet().toList()..sort();
    // Bound pathological contours independently from source mesh complexity.
    if (segments.length * levels.length > 4000000) {
      return fail(SectionCapIssue.complexity);
    }
    var outputOverflow = false;
    final positions = <double>[], normals = <double>[], indices = <int>[];
    void triangle(Vec3 a, Vec3 b, Vec3 c) {
      var polygon = [a, b, c];
      for (var j = 0; j < planes.length; j++) {
        if (j == planeIndex || polygon.isEmpty) continue;
        final clipped = <Vec3>[], other = planes[j];
        for (var k = 0; k < polygon.length; k++) {
          final start = polygon[k], end = polygon[(k + 1) % polygon.length];
          final da = other.distanceTo(start), db = other.distanceTo(end);
          if (da >= 0) clipped.add(start);
          if ((da >= 0) != (db >= 0)) {
            clipped.add(start + (end - start) * (da / (da - db)));
          }
        }
        polygon = clipped;
      }
      for (var j = 1; j + 1 < polygon.length; j++) {
        final a = polygon[0], b = polygon[j], c = polygon[j + 1];
        if ((b - a).cross(c - a).length <= epsilon * epsilon) continue;
        if (indices.length + 3 > 3000000) {
          outputOverflow = true;
          return;
        }
        for (final p in [a, b, c]) {
          indices.add(indices.length);
          positions.addAll(p.storage);
          normals.addAll(normal.storage);
        }
      }
    }

    for (var band = 0; band + 1 < levels.length; band++) {
      final low = levels[band], high = levels[band + 1], mid = (low + high) / 2;
      if (high - low <= epsilon) continue;
      final active = <((int, int), double)>[];
      double xAt((int, int) s, double y) {
        final a = xy[s.$1], b = xy[s.$2];
        return a.$1 + (b.$1 - a.$1) * ((y - a.$2) / (b.$2 - a.$2));
      }

      for (final s in segments) {
        final a = xy[s.$1].$2, b = xy[s.$2].$2;
        if (mid > math.min(a, b) && mid < math.max(a, b)) {
          active.add((s, xAt(s, mid)));
        }
      }
      active.sort((a, b) => a.$2.compareTo(b.$2));
      if (active.length.isOdd) return fail(SectionCapIssue.topology);
      for (var j = 1; j < active.length; j++) {
        if (xAt(active[j - 1].$1, low) > xAt(active[j].$1, low) + epsilon ||
            xAt(active[j - 1].$1, high) > xAt(active[j].$1, high) + epsilon) {
          return fail(SectionCapIssue.topology);
        }
      }
      for (var j = 0; j < active.length; j += 2) {
        final left = active[j].$1, right = active[j + 1].$1;
        Vec3 at((int, int) s, double y) => origin + u * xAt(s, y) + v * y;
        final a = at(left, low),
            b = at(right, low),
            c = at(right, high),
            d = at(left, high);
        triangle(a, b, c);
        triangle(a, c, d);
      }
    }
    if (outputOverflow) return fail(SectionCapIssue.complexity);
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
