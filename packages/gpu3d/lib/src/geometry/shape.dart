import 'dart:math' as math;
import 'dart:typed_data';
import 'package:dart_earcut/dart_earcut.dart';
import '../math/vec2.dart';
import '../math/vec3.dart';
import 'geometry.dart';
import 'vertex_attribute.dart';

/// A simple XY contour with disjoint, strictly interior holes.
/// Rings are copied and canonicalized: contour CCW, holes CW. Repeating the
/// first point at the end is optional. Intersections and touching rings fail.
final class Shape2D {
  late final List<Vec2> contour;
  late final List<List<Vec2>> holes;
  late final List<Vec2> vertices;
  late final List<int> triangles;
  late final double area;
  Shape2D(List<Vec2> contour, {List<List<Vec2>> holes = const []}) {
    final count = contour.length + holes.fold<int>(0, (n, h) => n + h.length);
    if (count > 4096 || count < 3) {
      throw ArgumentError('Shapes support 3 to 4096 ring vertices.');
    }
    final rings = [contour, ...holes].map((input) {
      final ring = List<Vec2>.of(input);
      if (ring.length > 1 && ring.first == ring.last) ring.removeLast();
      if (ring.length < 3 || ring.any((v) => !v.isFinite)) {
        throw ArgumentError('Each ring needs at least three finite vertices.');
      }
      return ring;
    }).toList();
    final origin = rings.first.first;
    final scale = rings
        .expand((r) => r)
        .fold<double>(
          0,
          (s, p) => math.max(
            s,
            math.max((p.x - origin.x).abs(), (p.y - origin.y).abs()),
          ),
        );
    if (!scale.isFinite || scale == 0) {
      throw ArgumentError('Shape has no finite extent.');
    }
    var local = [
      for (final ring in rings) [for (final p in ring) (p - origin) / scale],
    ];
    for (var r = 0; r < rings.length; r++) {
      final ring = local[r];
      if (_area(ring).abs() <= 1e-12) {
        throw ArgumentError('Ring has no usable area.');
      }
      for (var i = 0; i < ring.length; i++) {
        final a = ring[i], b = ring[(i + 1) % ring.length];
        if ((b - a).length2 <= 1e-24) {
          throw ArgumentError('Ring has a collapsed edge.');
        }
        for (var j = i + 1; j < ring.length; j++) {
          if (j == i + 1 || (i == 0 && j == ring.length - 1)) continue;
          if (_intersects(a, b, ring[j], ring[(j + 1) % ring.length])) {
            throw ArgumentError('Ring intersects or touches itself.');
          }
        }
      }
      if ((_area(ring) > 0) != (r == 0)) rings[r] = rings[r].reversed.toList();
    }
    local = [
      for (final ring in rings) [for (final p in ring) (p - origin) / scale],
    ];
    for (var r = 1; r < local.length; r++) {
      if (!_contains(local.first, local[r].first)) {
        throw ArgumentError('Hole lies outside its contour.');
      }
      for (var q = 0; q < r; q++) {
        for (var i = 0; i < local[r].length; i++) {
          for (var j = 0; j < local[q].length; j++) {
            if (_intersects(
              local[r][i],
              local[r][(i + 1) % local[r].length],
              local[q][j],
              local[q][(j + 1) % local[q].length],
            )) {
              throw ArgumentError('Shape rings intersect or touch.');
            }
          }
        }
        if (q > 0 &&
            (_contains(local[q], local[r].first) ||
                _contains(local[r], local[q].first))) {
          throw ArgumentError('Holes cannot overlap or contain other holes.');
        }
      }
    }
    this.contour = List.unmodifiable(rings.first);
    this.holes = List.unmodifiable(
      rings.skip(1).map((r) => List<Vec2>.unmodifiable(r)),
    );
    vertices = List.unmodifiable(rings.expand((r) => r));
    final flattened = local.expand((r) => r).toList();
    final starts = <int>[];
    var offset = local.first.length;
    for (final ring in local.skip(1)) {
      starts.add(offset);
      offset += ring.length;
    }
    final indices = Earcut.triangulateRaw([
      for (final p in flattened) ...[p.x, p.y],
    ], holeIndices: starts);
    final canonical = <int>[];
    var covered = 0.0;
    for (var i = 0; i < indices.length; i += 3) {
      final a = indices[i], b = indices[i + 1], c = indices[i + 2];
      final signed = (flattened[b] - flattened[a]).cross(
        flattened[c] - flattened[a],
      );
      if (signed.abs() <= 1e-20) continue;
      covered += signed.abs() / 2;
      canonical.addAll(signed > 0 ? [a, b, c] : [a, c, b]);
    }
    final expected = local.fold<double>(0, (sum, r) => sum + _area(r));
    if (expected <= 0 ||
        (covered - expected).abs() > math.max(1e-10, expected * 1e-8) ||
        canonical.isEmpty) {
      throw ArgumentError('Shape cannot be triangulated without losing area.');
    }
    area = expected * scale * scale;
    if (!area.isFinite) {
      throw ArgumentError('Shape area exceeds finite storage.');
    }
    triangles = List.unmodifiable(canonical);
  }
}

double _area(List<Vec2> ring) {
  var sum = 0.0;
  final origin = ring.first;
  for (var i = 0; i < ring.length; i++) {
    sum += (ring[i] - origin).cross(ring[(i + 1) % ring.length] - origin);
  }
  return sum / 2;
}

bool _contains(List<Vec2> ring, Vec2 point) {
  var inside = false;
  for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    final a = ring[i], b = ring[j];
    if ((a.y > point.y) != (b.y > point.y) &&
        point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x) {
      inside = !inside;
    }
  }
  return inside;
}

bool _intersects(Vec2 a, Vec2 b, Vec2 c, Vec2 d) {
  const epsilon = 1e-12;
  double orientation(Vec2 p, Vec2 q, Vec2 r) => (q - p).cross(r - p);
  bool on(Vec2 p, Vec2 q, Vec2 r) =>
      r.x >= math.min(p.x, q.x) - epsilon &&
      r.x <= math.max(p.x, q.x) + epsilon &&
      r.y >= math.min(p.y, q.y) - epsilon &&
      r.y <= math.max(p.y, q.y) + epsilon;
  final x = orientation(a, b, c),
      y = orientation(a, b, d),
      z = orientation(c, d, a),
      w = orientation(c, d, b);
  return ((x > epsilon && y < -epsilon || x < -epsilon && y > epsilon) &&
          (z > epsilon && w < -epsilon || z < -epsilon && w > epsilon)) ||
      x.abs() <= epsilon && on(a, b, c) ||
      y.abs() <= epsilon && on(a, b, d) ||
      z.abs() <= epsilon && on(c, d, a) ||
      w.abs() <= epsilon && on(c, d, b);
}

/// A triangulated XY surface facing +Z, with local XY coordinates as UVs.
final class ShapeGeometry extends BufferGeometry {
  ShapeGeometry(Shape2D shape, {super.indexFormat})
    : super(
        positions: [
          for (final p in shape.vertices) ...[p.x, p.y, 0.0],
        ],
        normals: [
          for (final _ in shape.vertices) ...[0.0, 0.0, 1.0],
        ],
        uv0: [
          for (final p in shape.vertices) ...[p.x, p.y],
        ],
        indices: shape.triangles,
      );
}

/// Extrudes along +Z, with optional faceted quarter-ellipse bevels.
/// Caps, wall edges and bevel segments have separate normals and UV seams.
final class ExtrudeGeometry extends BufferGeometry {
  ExtrudeGeometry(
    Shape2D shape, {
    double depth = 1,
    int steps = 1,
    bool capStart = true,
    bool capEnd = true,
    double bevelSize = 0,
    double? bevelThickness,
    int bevelSegments = 1,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) : super.fromData(
         _extrude(
           shape,
           depth,
           steps,
           capStart,
           capEnd,
           bevelSize,
           bevelThickness ?? bevelSize,
           bevelSegments,
           indexFormat,
         ),
       );
}

GeometryData _extrude(
  Shape2D shape,
  double depth,
  int steps,
  bool capStart,
  bool capEnd,
  double bevelSize,
  double bevelThickness,
  int bevelSegments,
  IndexFormat format,
) {
  if (!depth.isFinite ||
      depth <= 0 ||
      steps < 1 ||
      !bevelSize.isFinite ||
      bevelSize < 0 ||
      !bevelThickness.isFinite ||
      bevelThickness < 0 ||
      bevelThickness * 2 >= depth ||
      (bevelSize > 0) != (bevelThickness > 0) ||
      bevelSegments < 1 ||
      bevelSegments > 32) {
    throw ArgumentError(
      'Extrusion needs positive depth/steps and a bevel thinner than half its depth.',
    );
  }
  final n = shape.vertices.length,
      segments = steps + (bevelSize > 0 ? bevelSegments * 2 : 0);
  final caps = (capStart ? 1 : 0) + (capEnd ? 1 : 0);
  if (4 * n * segments + caps * n >
          (format == IndexFormat.uint16 ? 65536 : 1000000) ||
      6 * n * segments + caps * shape.triangles.length > 3000000) {
    throw ArgumentError('Extrusion exceeds the geometry budget.');
  }
  final rings = [shape.contour, ...shape.holes];
  final miters = <List<Vec2>>[
    if (bevelSize > 0)
      for (final ring in rings)
        [for (var i = 0; i < ring.length; i++) _miter(ring, i)],
  ];
  List<List<Vec2>> inset(double distance) => [
    for (var r = 0; r < rings.length; r++)
      [
        for (var i = 0; i < rings[r].length; i++)
          rings[r][i] + miters[r][i] * distance,
      ],
  ];
  final levels = <(double, List<List<Vec2>>)>[];
  if (bevelSize > 0) {
    for (var step = 0; step < bevelSegments; step++) {
      final angle = step / bevelSegments * math.pi / 2;
      levels.add((
        bevelThickness * (1 - math.cos(angle)),
        inset(bevelSize * (1 - math.sin(angle))),
      ));
    }
  }
  for (var step = 0; step <= steps; step++) {
    levels.add((
      bevelThickness + (depth - 2 * bevelThickness) * step / steps,
      rings,
    ));
  }
  if (bevelSize > 0) {
    for (var step = 1; step <= bevelSegments; step++) {
      final angle = step / bevelSegments * math.pi / 2;
      levels.add((
        depth - bevelThickness + bevelThickness * math.sin(angle),
        inset(bevelSize * (1 - math.cos(angle))),
      ));
    }
  }
  Shape2D capShape = shape;
  if (bevelSize > 0) {
    // Fail closed if an inset changes topology, reverses winding or closes a gap.
    for (final level in levels) {
      if (identical(level.$2, rings)) continue;
      for (var r = 0; r < rings.length; r++) {
        if ((_area(level.$2[r]) > 0) != (r == 0)) {
          throw ArgumentError('Bevel collapses a ring.');
        }
        for (var i = 0; i < rings[r].length; i++) {
          final j = (i + 1) % rings[r].length;
          if ((level.$2[r][j] - level.$2[r][i]).dot(
                rings[r][j] - rings[r][i],
              ) <=
              0) {
            throw ArgumentError('Bevel reverses an edge.');
          }
        }
      }
      final checked = Shape2D(level.$2.first, holes: level.$2.skip(1).toList());
      if (level == levels.first) capShape = checked;
    }
  }
  final positions = <double>[],
      normals = <double>[],
      uv = <double>[],
      indices = <int>[];
  void vertex(Vec3 p, Vec3 normal, Vec2 texture) {
    positions.addAll(p.storage);
    normals.addAll(normal.storage);
    uv.addAll([texture.x, texture.y]);
  }

  for (final end in [false, true]) {
    if (end ? !capEnd : !capStart) continue;
    final start = positions.length ~/ 3;
    for (final p in capShape.vertices) {
      vertex(Vec3(p.x, p.y, end ? depth : 0), Vec3(0, 0, end ? 1 : -1), p);
    }
    for (var i = 0; i < capShape.triangles.length; i += 3) {
      final a = start + capShape.triangles[i],
          b = start + capShape.triangles[i + 1],
          c = start + capShape.triangles[i + 2];
      indices.addAll(end ? [a, b, c] : [a, c, b]);
    }
  }
  for (var r = 0; r < rings.length; r++) {
    final ring = rings[r];
    var perimeter = 0.0;
    for (var i = 0; i < ring.length; i++) {
      final j = (i + 1) % ring.length, length = (ring[j] - ring[i]).length;
      for (var step = 0; step < levels.length - 1; step++) {
        final lo = levels[step],
            hi = levels[step + 1],
            start = positions.length ~/ 3;
        final a = Vec3(lo.$2[r][i].x, lo.$2[r][i].y, lo.$1);
        final b = Vec3(lo.$2[r][j].x, lo.$2[r][j].y, lo.$1);
        final c = Vec3(hi.$2[r][j].x, hi.$2[r][j].y, hi.$1);
        final d = Vec3(hi.$2[r][i].x, hi.$2[r][i].y, hi.$1);
        final normal = (b - a).cross(c - a).normalized();
        vertex(a, normal, Vec2(perimeter, lo.$1));
        vertex(b, normal, Vec2(perimeter + length, lo.$1));
        vertex(c, normal, Vec2(perimeter + length, hi.$1));
        vertex(d, normal, Vec2(perimeter, hi.$1));
        indices.addAll([
          start,
          start + 1,
          start + 2,
          start,
          start + 2,
          start + 3,
        ]);
      }
      perimeter += length;
    }
  }
  return GeometryData(
    attributes: {
      VertexSemantic.position: VertexAttribute(
        Float32List.fromList(positions),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.normal: VertexAttribute(
        Float32List.fromList(normals),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.uv0: VertexAttribute(
        Float32List.fromList(uv),
        format: VertexFormat.float32x2,
      ),
    },
    indices: indices,
    indexFormat: format,
  );
}

Vec2 _miter(List<Vec2> ring, int i) {
  final incoming = (ring[i] - ring[(i + ring.length - 1) % ring.length])
      .normalized();
  final outgoing = (ring[(i + 1) % ring.length] - ring[i]).normalized();
  final leftA = Vec2(-incoming.y, incoming.x),
      leftB = Vec2(-outgoing.y, outgoing.x);
  final denominator = 1 + incoming.dot(outgoing);
  if (denominator < 1e-8) {
    throw ArgumentError('Bevel cannot offset a reversing edge.');
  }
  return (leftA + leftB) / denominator;
}
