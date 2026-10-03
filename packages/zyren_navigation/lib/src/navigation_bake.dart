import 'dart:math' as math;
import 'package:zyren/zyren.dart';

final class NavigationBakeSettings {
  final double cellSize, radius, height, maxSlope, maxStep;
  final int maxCells, maxTriangles, maxOperations;
  NavigationBakeSettings({
    this.cellSize = .2,
    this.radius = .3,
    this.height = 1.8,
    this.maxSlope = math.pi / 4,
    this.maxStep = .25,
    this.maxCells = 16384,
    this.maxTriangles = 8192,
    this.maxOperations = 4000000,
  }) {
    if (![
          cellSize,
          radius,
          height,
          maxSlope,
          maxStep,
        ].every((v) => v.isFinite && v >= 0) ||
        cellSize < .01 ||
        height <= 0 ||
        maxSlope >= math.pi / 2 ||
        maxCells < 1 ||
        maxCells > 65536 ||
        maxTriangles < 1 ||
        maxTriangles > 65536 ||
        maxOperations < 1 ||
        maxOperations > 50000000) {
      throw ArgumentError('Invalid navigation bake settings or budgets.');
    }
  }
  Map<String, Object> get json => {
    'cellSize': cellSize,
    'radius': radius,
    'height': height,
    'maxSlope': maxSlope,
    'maxStep': maxStep,
    'maxCells': maxCells,
    'maxTriangles': maxTriangles,
    'maxOperations': maxOperations,
  };
}

/// World-space source triangles, captured with host-owned identity and revision.
final class NavigationGeometry {
  final String sourceId, revision;
  final List<Vec3> vertices;
  final List<List<int>> triangles;
  NavigationGeometry({
    required this.sourceId,
    required this.revision,
    required Iterable<Vec3> vertices,
    required Iterable<List<int>> triangles,
  }) : vertices = List.unmodifiable(vertices),
       triangles = List.unmodifiable(triangles.map(List<int>.unmodifiable)) {
    if (sourceId.trim().isEmpty ||
        revision.trim().isEmpty ||
        this.vertices.isEmpty ||
        this.vertices.length > 196608 ||
        this.triangles.length > 65536 ||
        this.vertices.any(
          (v) => !v.isFinite || v.storage.any((x) => x.abs() > 10000),
        ) ||
        this.triangles.any(
          (t) =>
              t.length != 3 || t.any((i) => i < 0 || i >= this.vertices.length),
        )) {
      throw ArgumentError('Invalid navigation source geometry or identity.');
    }
  }
  factory NavigationGeometry.fromMesh(
    Mesh mesh, {
    required String sourceId,
    required String revision,
  }) {
    if (mesh is SkinnedMesh || mesh.geometry.morphTargets.isNotEmpty) {
      throw ArgumentError('Bake a static geometry snapshot before navigation.');
    }
    if (mesh.geometry.topology != GeometryTopology.triangles) {
      throw ArgumentError('Navigation sources must use triangle lists.');
    }
    final p = mesh.geometry.positions,
        indices = mesh.geometry.indices,
        m = mesh.worldMatrix.storage;
    final vertices = <Vec3>[];
    for (var i = 0; i < p.length; i += 3) {
      final x = p[i], y = p[i + 1], z = p[i + 2];
      vertices.add(
        Vec3(
          m[0] * x + m[4] * y + m[8] * z + m[12],
          m[1] * x + m[5] * y + m[9] * z + m[13],
          m[2] * x + m[6] * y + m[10] * z + m[14],
        ),
      );
    }
    return NavigationGeometry(
      sourceId: sourceId,
      revision: revision,
      vertices: vertices,
      triangles: [
        for (var i = 0; i < indices.length; i += 3) indices.sublist(i, i + 3),
      ],
    );
  }
}

final class NavigationCell {
  final int id, x, z;
  final Vec3 center;
  final List<Vec3> corners;
  final Set<String> sourceIds;
  const NavigationCell._(
    this.id,
    this.x,
    this.z,
    this.center,
    this.corners,
    this.sourceIds,
  );
}

/// Immutable layered surface mesh. Each cell has two triangles and four-neighbor
/// links. Baking erodes whole cells, so clearance is conservative at this resolution.
final class BakedNavigationMesh {
  final NavigationBakeSettings settings;
  final List<NavigationCell> cells;
  final List<List<int>> neighbors;
  final Map<String, String> sources;
  final List<NavigationGeometry> geometry;
  const BakedNavigationMesh._(
    this.settings,
    this.cells,
    this.neighbors,
    this.sources,
    this.geometry,
  );
  List<Vec3> get vertices =>
      List.unmodifiable([for (final c in cells) ...c.corners]);
  List<List<int>> get triangles => List.unmodifiable([
    for (final c in cells) ...[
      [c.id * 4, c.id * 4 + 2, c.id * 4 + 1],
      [c.id * 4, c.id * 4 + 3, c.id * 4 + 2],
    ],
  ]);
  int? locate(Vec3 point, {double tolerance = .05}) {
    if (!point.isFinite || !tolerance.isFinite || tolerance < 0) {
      throw ArgumentError('Invalid location query.');
    }
    int? best;
    var distance = double.infinity;
    for (final c in cells) {
      if ((point.x - c.center.x).abs() > settings.cellSize / 2 + 1e-8 ||
          (point.z - c.center.z).abs() > settings.cellSize / 2 + 1e-8) {
        continue;
      }
      final a = c.corners[0], b = c.corners[1], d = c.corners[3];
      final y =
          a.y +
          (b.y - a.y) * (point.x - a.x) / settings.cellSize +
          (d.y - a.y) * (point.z - a.z) / settings.cellSize;
      final dy = (point.y - y).abs();
      if (dy <= tolerance && dy < distance) {
        best = c.id;
        distance = dy;
      }
    }
    return best;
  }
}

final class NavigationBakeCancelled implements Exception {}

final class NavigationBakeBudgetExceeded implements Exception {}

final class NavigationBaker {
  final NavigationBakeSettings settings;
  NavigationBaker({NavigationBakeSettings? settings})
    : settings = settings ?? NavigationBakeSettings();
  BakedNavigationMesh bake(
    Iterable<NavigationGeometry> input, {
    bool Function()? cancelled,
  }) {
    final sources = List<NavigationGeometry>.of(input);
    if (sources.isEmpty ||
        sources.map((s) => s.sourceId).toSet().length != sources.length) {
      throw ArgumentError('Bake sources need unique IDs.');
    }
    final triangles = <_Triangle>[];
    for (final source in sources) {
      for (final t in source.triangles) {
        if (triangles.length >= settings.maxTriangles) {
          throw NavigationBakeBudgetExceeded();
        }
        final tri = _Triangle(
          source.sourceId,
          source.vertices[t[0]],
          source.vertices[t[1]],
          source.vertices[t[2]],
        );
        if (tri.normal.length2 > 1e-18) triangles.add(tri);
      }
    }
    var operations = 0;
    void check() {
      if (cancelled?.call() == true) throw NavigationBakeCancelled();
      if (++operations > settings.maxOperations) {
        throw NavigationBakeBudgetExceeded();
      }
    }

    final size = settings.cellSize, buckets = <(int, int), List<_Triangle>>{};
    for (final tri in triangles) {
      for (
        var x = (tri.minX / size).floor();
        x <= (tri.maxX / size).floor();
        x++
      ) {
        for (
          var z = (tri.minZ / size).floor();
          z <= (tri.maxZ / size).floor();
          z++
        ) {
          check();
          buckets.putIfAbsent((x, z), () => []).add(tri);
          if (buckets.length > settings.maxCells * 4) {
            throw NavigationBakeBudgetExceeded();
          }
        }
      }
    }
    final candidates = <(int, int), List<_Cell>>{};
    for (final entry in buckets.entries) {
      final (x, z) = entry.key;
      final corners = [
        Vec3(x * size, 0, z * size),
        Vec3((x + 1) * size, 0, z * size),
        Vec3((x + 1) * size, 0, (z + 1) * size),
        Vec3(x * size, 0, (z + 1) * size),
      ];
      final planes = <_Triangle>[];
      for (final tri in entry.value) {
        check();
        if (tri.normal.normalized().y < math.cos(settings.maxSlope)) continue;
        if (planes.any((other) => other.samePlane(tri))) continue;
        planes.add(tri);
        var uncovered = <List<Vec3>>[corners];
        final ids = <String>{};
        for (final patch in entry.value.where(tri.samePlane)) {
          ids.add(patch.source);
          uncovered = [
            for (final polygon in uncovered) ..._subtract(polygon, patch),
          ];
          check();
          if (uncovered.length > 256) throw NavigationBakeBudgetExceeded();
          if (uncovered.isEmpty) break;
        }
        if (uncovered.isNotEmpty) continue;
        final surface = [
          for (final p in corners) Vec3(p.x, tri.y(p.x, p.z), p.z),
        ];
        final y = tri.y((x + .5) * size, (z + .5) * size);
        final minY = surface.map((p) => p.y).reduce(math.min),
            maxY = surface.map((p) => p.y).reduce(math.max);
        final blocked = entry.value.any((obstacle) {
          if (tri.samePlane(obstacle)) return false;
          if (obstacle.maxY <= minY + settings.maxStep + 1e-7 ||
              obstacle.minY >= minY + settings.height - 1e-7) {
            return false;
          }
          return obstacle.minX <= (x + 1) * size + 1e-8 &&
              obstacle.maxX >= x * size - 1e-8 &&
              obstacle.minZ <= (z + 1) * size + 1e-8 &&
              obstacle.maxZ >= z * size - 1e-8 &&
              obstacle.maxY > maxY + 1e-7;
        });
        if (!blocked) {
          candidates
              .putIfAbsent(entry.key, () => [])
              .add(_Cell(x, z, y, surface, ids));
        }
      }
    }
    final erode = (settings.radius / size).ceil();
    final cells = <NavigationCell>[];
    for (final column in candidates.values) {
      for (final c in column) {
        var clear = true;
        for (var dx = -erode; dx <= erode && clear; dx++) {
          for (var dz = -erode; dz <= erode; dz++) {
            check();
            final adjacent = candidates[(c.x + dx, c.z + dz)] ?? [];
            final expected = _height(
              c.corners,
              (c.x + dx + .5) * size,
              (c.z + dz + .5) * size,
              size,
            );
            if (!adjacent.any(
              (other) => (other.y - expected).abs() <= settings.maxStep + 1e-7,
            )) {
              clear = false;
              break;
            }
          }
        }
        if (!clear) continue;
        if (cells.length >= settings.maxCells) {
          throw NavigationBakeBudgetExceeded();
        }
        cells.add(
          NavigationCell._(
            cells.length,
            c.x,
            c.z,
            Vec3((c.x + .5) * size, c.y, (c.z + .5) * size),
            List.unmodifiable(c.corners),
            Set.unmodifiable(c.ids),
          ),
        );
      }
    }
    final index = <(int, int), List<NavigationCell>>{};
    for (final c in cells) {
      index.putIfAbsent((c.x, c.z), () => []).add(c);
    }
    final neighbors = <List<int>>[];
    for (final c in cells) {
      final next = <int>[];
      for (final (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        for (final other in index[(c.x + dx, c.z + dz)] ?? <NavigationCell>[]) {
          check();
          final mx = (c.center.x + other.center.x) / 2,
              mz = (c.center.z + other.center.z) / 2;
          if ((_height(c.corners, mx, mz, size) -
                      _height(other.corners, mx, mz, size))
                  .abs() <=
              settings.maxStep + 1e-7) {
            next.add(other.id);
          }
        }
      }
      neighbors.add(List.unmodifiable(next..sort()));
    }
    return BakedNavigationMesh._(
      settings,
      List.unmodifiable(cells),
      List.unmodifiable(neighbors),
      Map.unmodifiable({for (final s in sources) s.sourceId: s.revision}),
      List.unmodifiable(sources),
    );
  }
}

double _height(List<Vec3> c, double x, double z, double size) =>
    c[0].y +
    (c[1].y - c[0].y) * (x - c[0].x) / size +
    (c[3].y - c[0].y) * (z - c[0].z) / size;

final class _Cell {
  final int x, z;
  final double y;
  final List<Vec3> corners;
  final Set<String> ids;
  _Cell(this.x, this.z, this.y, this.corners, this.ids);
}

final class _Triangle {
  final String source;
  final Vec3 a, b, c;
  late final Vec3 normal = (b - a).cross(c - a);
  late final double minX = math.min(a.x, math.min(b.x, c.x)),
      maxX = math.max(a.x, math.max(b.x, c.x)),
      minZ = math.min(a.z, math.min(b.z, c.z)),
      maxZ = math.max(a.z, math.max(b.z, c.z)),
      minY = math.min(a.y, math.min(b.y, c.y)),
      maxY = math.max(a.y, math.max(b.y, c.y));
  _Triangle(this.source, this.a, this.b, this.c);
  double y(double x, double z) =>
      a.y - (normal.x * (x - a.x) + normal.z * (z - a.z)) / normal.y;
  bool samePlane(_Triangle t) =>
      normal.normalized().dot(t.normal.normalized()) > 1 - 1e-9 &&
      (t.a - a).dot(normal.normalized()).abs() < 1e-7;
}

// Convex polygon subtraction keeps uncovered pieces. It does not fill small holes
// with sample-point guesses or count overlapping triangles twice.
List<List<Vec3>> _subtract(List<Vec3> polygon, _Triangle t) {
  var inside = polygon;
  final outside = <List<Vec3>>[];
  final tri = [t.a, t.c, t.b]; // Upward Y normals project clockwise in XZ.
  for (var i = 0; i < 3; i++) {
    final a = tri[i], b = tri[(i + 1) % 3];
    double side(Vec3 p) =>
        (b.x - a.x) * (p.z - a.z) - (b.z - a.z) * (p.x - a.x);
    List<Vec3> clip(bool keepInside) {
      final out = <Vec3>[];
      for (var j = 0; j < inside.length; j++) {
        final p = inside[j],
            q = inside[(j + 1) % inside.length],
            u = side(p),
            v = side(q);
        final pin = keepInside ? u >= 0 : u <= 0,
            qin = keepInside ? v >= 0 : v <= 0;
        if (pin) out.add(p);
        if (pin != qin) out.add(p + (q - p) * (u / (u - v)));
      }
      return out;
    }

    final remainder = clip(false);
    if (_area(remainder) > 1e-12) outside.add(remainder);
    inside = clip(true);
    if (_area(inside) <= 1e-12) break;
  }
  return outside;
}

double _area(List<Vec3> p) {
  var area = 0.0;
  for (var i = 0; i < p.length; i++) {
    final a = p[i], b = p[(i + 1) % p.length];
    area += a.x * b.z - b.x * a.z;
  }
  return area.abs() / 2;
}
