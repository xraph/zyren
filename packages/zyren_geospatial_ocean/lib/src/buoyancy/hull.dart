part of 'probes.dart';

/// Closed, consistently outward-wound convex triangle mesh in body-local metres.
/// Cells are a disjoint star decomposition, optionally bisected on longest edges.
final class BuoyancyHull extends BuoyancyShape {
  final List<Vec3> vertices;
  final List<int> indices;
  late final List<BuoyancyTetrahedron> cells;
  @override
  late final double volume;
  BuoyancyHull({
    required List<Vec3> vertices,
    required List<int> indices,
    int subdivisions = 0,
  }) : vertices = List.unmodifiable(vertices),
       indices = List.unmodifiable(indices) {
    if (vertices.length < 4 ||
        vertices.length > 1024 ||
        indices.length < 12 ||
        indices.length > 6144 ||
        indices.length % 3 != 0 ||
        subdivisions < 0 ||
        subdivisions > 8 ||
        (indices.length ~/ 3) * (1 << subdivisions) > 4096 ||
        vertices.any((v) => !v.isFinite || v.length > 1e9) ||
        indices.any((i) => i < 0 || i >= vertices.length)) {
      throw ArgumentError('Invalid bounded convex hull input.');
    }
    final origin = vertices.first;
    final center =
        origin +
        vertices.fold(Vec3.zero, (s, v) => s + (v - origin)) /
            vertices.length.toDouble();
    final scale = vertices.map((v) => v.distanceTo(center)).reduce(math.max);
    if (scale == 0 || scale > 1e6) throw ArgumentError('Invalid hull extent.');
    final tolerance = scale * 1e-10;
    for (var i = 0; i < vertices.length; i++) {
      for (var j = i + 1; j < vertices.length; j++) {
        if (vertices[i].distanceTo(vertices[j]) <= tolerance) {
          throw ArgumentError('Hull vertices must be distinct.');
        }
      }
    }
    final edges = <(int, int), List<(int, int)>>{}, used = <int>{};
    var built = <BuoyancyTetrahedron>[];
    for (var face = 0; face < indices.length; face += 3) {
      final a = indices[face], b = indices[face + 1], c = indices[face + 2];
      used.addAll([a, b, c]);
      final raw = (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]);
      if (raw.length <= scale * scale * 1e-12) {
        throw ArgumentError('Degenerate hull face.');
      }
      final n = raw.normalized();
      if ((center - vertices[a]).dot(n) >= -tolerance ||
          vertices.any((v) => (v - vertices[a]).dot(n) > tolerance)) {
        throw ArgumentError(
          'Hull must be convex and all faces consistently outward.',
        );
      }
      for (final e in [(a, b), (b, c), (c, a)]) {
        (edges[(math.min(e.$1, e.$2), math.max(e.$1, e.$2))] ??= []).add(e);
      }
      built.add(
        BuoyancyTetrahedron(center, vertices[a], vertices[b], vertices[c]),
      );
    }
    if (used.length != vertices.length ||
        vertices.length - edges.length + indices.length ~/ 3 != 2 ||
        edges.values.any(
          (e) => e.length != 2 || e[0].$1 != e[1].$2 || e[0].$2 != e[1].$1,
        )) {
      throw ArgumentError(
        'Hull must be closed and manifold without unused vertices.',
      );
    }
    for (var i = 0; i < subdivisions; i++) {
      built = [for (final cell in built) ...cell.bisect()];
    }
    cells = List.unmodifiable(built);
    volume = cells.fold(0.0, (sum, c) => sum + c.volume);
  }
  @override
  List<Vec3> get quadraturePoints =>
      List.unmodifiable(cells.map((c) => c.centroid));
  @override
  double get maximumCellDiameter =>
      cells.map((c) => c.diameter).reduce(math.max);
}
