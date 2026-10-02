import 'package:zyren/zyren.dart';

/// A query distinguishes a missing route from an exhausted search budget.
enum NavigationStatus {
  found,
  startOutside,
  goalOutside,
  disconnected,
  budgetExceeded,
}

/// A point-agent route through shared edge midpoints, without radius clearance.
final class NavigationPath {
  final NavigationStatus status;
  final List<int> triangles;
  final List<Vec3> points;
  final int visited;
  late final double length = _lengths.fold(0, (sum, value) => sum + value);
  late final List<double> _lengths = [
    for (var i = 1; i < points.length; i++) (points[i] - points[i - 1]).length,
  ];
  NavigationPath._(
    this.status,
    Iterable<int> triangles,
    Iterable<Vec3> points,
    this.visited,
  ) : triangles = List.unmodifiable(triangles),
      points = List.unmodifiable(points);

  /// Clamps a finite distance in metres to this successful route.
  Vec3 pointAt(double distance) {
    if (!distance.isFinite || distance < 0) {
      throw ArgumentError('Distance must be finite and nonnegative.');
    }
    if (status != NavigationStatus.found) {
      throw StateError('The query has no route.');
    }
    var remaining = distance;
    for (var i = 0; i < _lengths.length; i++) {
      final segment = _lengths[i];
      if (segment > 0 && remaining < segment) {
        return points[i] + (points[i + 1] - points[i]) * (remaining / segment);
      }
      remaining -= segment;
    }
    return points.last;
  }
}

/// Immutable indexed triangles on one horizontal plane.
///
/// Coordinates must fit +/- 10 km. Meshes contain at most 1024 triangles and
/// 3072 vertices. Validation is quadratic; shared edges must share vertex IDs.
final class NavigationMesh {
  static const double tolerance = 1e-8;
  final List<Vec3> vertices;
  final List<List<int>> triangles;
  final List<Map<int, Vec3>> _neighbors;
  final List<Vec3> _centers;
  final double elevation;

  factory NavigationMesh({
    required Iterable<Vec3> vertices,
    required Iterable<List<int>> triangles,
  }) {
    final vs = List<Vec3>.unmodifiable(vertices.take(3073));
    final ts = triangles
        .take(1025)
        .map((t) => List<int>.of(t.take(4)))
        .toList();
    if (vs.length < 3 || vs.length > 3072 || ts.isEmpty || ts.length > 1024) {
      throw ArgumentError('Use 3..3072 vertices and 1..1024 triangles.');
    }
    final height = vs.first.y;
    final coordinates = <(double, double)>{};
    for (final v in vs) {
      if (!v.isFinite ||
          v.storage.any((n) => n.abs() > 10000) ||
          v.y != height ||
          !coordinates.add((v.x, v.z))) {
        throw ArgumentError(
          'Vertices must be finite, unique, bounded and on one horizontal plane.',
        );
      }
    }
    final edges = <(int, int), List<int>>{};
    for (var i = 0; i < ts.length; i++) {
      final t = ts[i];
      if (t.length != 3 ||
          t.toSet().length != 3 ||
          t.any((j) => j < 0 || j >= vs.length)) {
        throw ArgumentError(
          'Each triangle needs three distinct valid vertex indices.',
        );
      }
      final area = _cross(vs[t[0]], vs[t[1]], vs[t[2]]);
      if (area.abs() <= tolerance) {
        throw ArgumentError('Degenerate triangle $i.');
      }
      if (area < 0) {
        final old = t[1];
        t[1] = t[2];
        t[2] = old;
      }
      for (var j = 0; j < 3; j++) {
        final a = t[j], b = t[(j + 1) % 3];
        final key = a < b ? (a, b) : (b, a);
        final owners = edges.putIfAbsent(key, () => [])..add(i);
        if (owners.length > 2) throw ArgumentError('Non-manifold edge $key.');
      }
    }
    for (final edge in edges.keys) {
      final a = vs[edge.$1], b = vs[edge.$2];
      for (var i = 0; i < vs.length; i++) {
        if (i == edge.$1 || i == edge.$2) continue;
        final p = vs[i];
        if (_cross(a, b, p).abs() <= tolerance &&
            (p - a).dot(p - b) < -tolerance) {
          throw ArgumentError('Vertex $i makes a T-junction on $edge.');
        }
      }
    }
    for (var i = 0; i < ts.length; i++) {
      for (var j = i + 1; j < ts.length; j++) {
        if (_overlaps(ts[i], ts[j], vs)) {
          throw ArgumentError('Triangles $i and $j overlap.');
        }
      }
    }
    final neighbors = List.generate(ts.length, (_) => <int, Vec3>{});
    for (final entry in edges.entries) {
      if (entry.value.length != 2) continue;
      final a = entry.value[0], b = entry.value[1];
      final portal = (vs[entry.key.$1] + vs[entry.key.$2]) * .5;
      neighbors[a][b] = portal;
      neighbors[b][a] = portal;
    }
    return NavigationMesh._(
      vs,
      List.unmodifiable(ts.map(List<int>.unmodifiable)),
      neighbors,
      [for (final t in ts) (vs[t[0]] + vs[t[1]] + vs[t[2]]) * (1 / 3)],
      height,
    );
  }
  NavigationMesh._(
    this.vertices,
    this.triangles,
    this._neighbors,
    this._centers,
    this.elevation,
  );

  /// Returns the first containing triangle. Shared-edge ties use index order.
  int? locate(Vec3 point) {
    if (!point.isFinite) throw ArgumentError('Query points must be finite.');
    if ((point.y - elevation).abs() > tolerance) return null;
    for (var i = 0; i < triangles.length; i++) {
      final t = triangles[i];
      if (_cross(vertices[t[0]], vertices[t[1]], point) >= -tolerance &&
          _cross(vertices[t[1]], vertices[t[2]], point) >= -tolerance &&
          _cross(vertices[t[2]], vertices[t[0]], point) >= -tolerance) {
        return i;
      }
    }
    return null;
  }

  /// Searches a centroid graph, then connects shared edge midpoints.
  ///
  /// The resulting route stays inside the corridor but need not be shortest.
  /// [maxVisited] bounds expanded triangles; no partial route is returned.
  NavigationPath findPath(Vec3 start, Vec3 goal, {int? maxVisited}) {
    if (!start.isFinite || !goal.isFinite) {
      throw ArgumentError('Query points must be finite.');
    }
    final budget = maxVisited ?? triangles.length;
    if (budget < 1 || budget > triangles.length) {
      throw ArgumentError('Search budget must fit the triangle count.');
    }
    NavigationPath failed(NavigationStatus status, [int visited = 0]) =>
        NavigationPath._(status, const [], const [], visited);
    final source = locate(start), target = locate(goal);
    if (source == null) return failed(NavigationStatus.startOutside);
    if (target == null) return failed(NavigationStatus.goalOutside);
    final open = <int>{source}, closed = <int>{};
    final cost = <int, double>{source: 0}, parent = <int, int>{};
    double score(int i) => cost[i]! + (_centers[i] - _centers[target]).length;
    while (open.isNotEmpty) {
      if (closed.length >= budget) {
        return failed(NavigationStatus.budgetExceeded, closed.length);
      }
      final current = open.reduce(
        (a, b) => score(a) < score(b) || score(a) == score(b) && a < b ? a : b,
      );
      open.remove(current);
      closed.add(current);
      if (current == target) {
        final corridor = <int>[target];
        while (corridor.last != source) {
          corridor.add(parent[corridor.last]!);
        }
        final ordered = corridor.reversed.toList();
        return NavigationPath._(NavigationStatus.found, ordered, [
          start,
          for (var i = 1; i < ordered.length; i++)
            _neighbors[ordered[i - 1]][ordered[i]]!,
          goal,
        ], closed.length);
      }
      for (final next in _neighbors[current].keys) {
        if (closed.contains(next)) continue;
        final candidate =
            cost[current]! + (_centers[current] - _centers[next]).length;
        if (candidate < (cost[next] ?? double.infinity)) {
          cost[next] = candidate;
          parent[next] = current;
          open.add(next);
        }
      }
    }
    return failed(NavigationStatus.disconnected, closed.length);
  }
}

double _cross(Vec3 a, Vec3 b, Vec3 p) =>
    (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x);

bool _overlaps(List<int> a, List<int> b, List<Vec3> vs) {
  // For CCW convex triangles, any separating edge excludes interior overlap.
  for (final pair in [(a, b), (b, a)]) {
    for (var i = 0; i < 3; i++) {
      final p = vs[pair.$1[i]], q = vs[pair.$1[(i + 1) % 3]];
      if (pair.$2.every((j) => _cross(p, q, vs[j]) <= NavigationMesh.tolerance)) {
        return false;
      }
    }
  }
  return true;
}
