import 'dart:math' as math;
import '../math/vec2.dart';
import '../math/quat.dart';
import '../math/curve3.dart';
import '../math/vec3.dart';
import 'geometry.dart';

const _tau = math.pi * 2;
void _positive(double value, String name, {bool zero = false}) {
  if (!value.isFinite || (zero ? value < 0 : value <= 0)) {
    throw ArgumentError.value(
      value,
      name,
      'Expected a finite ${zero ? 'nonnegative' : 'positive'} value.',
    );
  }
}

void _segments(int count, int minimum) {
  if (count < minimum || count > 1000000) {
    throw ArgumentError('Invalid segment count.');
  }
}

void _arc(double start, double length) {
  if (!start.isFinite || !length.isFinite || length <= 0 || length > _tau) {
    throw ArgumentError('Expected a finite start and arc length in (0, 2*pi].');
  }
}

void _budget(int vertices, int indices, IndexFormat format) {
  if (vertices > (format == IndexFormat.uint16 ? 65536 : 1000000) ||
      indices > 3000000) {
    throw ArgumentError('Tessellation exceeds the vertex or index budget.');
  }
}

class _Surface {
  final positions = <double>[], normals = <double>[], uv = <double>[];
  final indices = <int>[];
  int add(Vec3 point, Vec3 normal, double u, double v) {
    final index = positions.length ~/ 3;
    positions.addAll([point.x, point.y, point.z]);
    normals.addAll([normal.x, normal.y, normal.z]);
    uv.addAll([u, v]);
    return index;
  }

  void triangle(int a, int b, int c) {
    final p = Vec3.array(positions, a * 3),
        q = Vec3.array(positions, b * 3),
        r = Vec3.array(positions, c * 3);
    if ((q - p).cross(r - p).length2 == 0) return;
    indices.addAll([a, b, c]);
  }

  void grid(int columns, int rows, {bool reverse = false}) {
    for (var y = 0; y < rows; y++) {
      for (var x = 0; x < columns; x++) {
        final a = y * (columns + 1) + x,
            b = a + columns + 1,
            c = b + 1,
            d = a + 1;
        if (reverse) {
          triangle(a, b, d);
          triangle(b, c, d);
        } else {
          triangle(a, d, b);
          triangle(b, d, c);
        }
      }
    }
  }
}

class _ProceduralGeometry extends BufferGeometry {
  _ProceduralGeometry(_Surface data, bool dynamic, IndexFormat format)
    : super(
        positions: data.positions,
        normals: data.normals,
        indices: data.indices,
        uv0: data.uv,
        dynamic: dynamic,
        indexFormat: format,
      );
}

/// XY disk facing +Z. Angles are radians, counterclockwise from +X.
class CircleGeometry extends _ProceduralGeometry {
  factory CircleGeometry({
    double radius = 1,
    int segments = 32,
    double thetaStart = 0,
    double thetaLength = _tau,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    _positive(radius, 'radius');
    _segments(segments, 3);
    _arc(thetaStart, thetaLength);
    _budget(segments + 2, segments * 3, indexFormat);
    final data = _Surface();
    data.add(Vec3.zero, const Vec3(0, 0, 1), .5, .5);
    for (var i = 0; i <= segments; i++) {
      final t = thetaStart + thetaLength * i / segments,
          x = math.cos(t),
          y = math.sin(t);
      data.add(
        Vec3(radius * x, radius * y, 0),
        const Vec3(0, 0, 1),
        x * .5 + .5,
        .5 - y * .5,
      );
      if (i > 0) data.triangle(0, i, i + 1);
    }
    return CircleGeometry._(data, dynamic, indexFormat);
  }
  CircleGeometry._(super.data, super.dynamic, super.format);
}

/// XY annulus facing +Z, with planar UVs and an optional angular cut.
class RingGeometry extends _ProceduralGeometry {
  factory RingGeometry({
    double innerRadius = .5,
    double outerRadius = 1,
    int thetaSegments = 32,
    int radialSegments = 1,
    double thetaStart = 0,
    double thetaLength = _tau,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    _positive(innerRadius, 'innerRadius', zero: true);
    _positive(outerRadius, 'outerRadius');
    if (innerRadius >= outerRadius) {
      throw ArgumentError('innerRadius must be less than outerRadius.');
    }
    _segments(thetaSegments, 3);
    _segments(radialSegments, 1);
    _arc(thetaStart, thetaLength);
    _budget(
      (thetaSegments + 1) * (radialSegments + 1),
      thetaSegments * radialSegments * 6,
      indexFormat,
    );
    final data = _Surface();
    for (var row = 0; row <= radialSegments; row++) {
      final r =
          outerRadius + (innerRadius - outerRadius) * row / radialSegments;
      for (var i = 0; i <= thetaSegments; i++) {
        final t = thetaStart + thetaLength * i / thetaSegments,
            x = r * math.cos(t),
            y = r * math.sin(t);
        data.add(
          Vec3(x, y, 0),
          const Vec3(0, 0, 1),
          x / outerRadius * .5 + .5,
          .5 - y / outerRadius * .5,
        );
      }
    }
    data.grid(thetaSegments, radialSegments);
    return RingGeometry._(data, dynamic, indexFormat);
  }
  RingGeometry._(super.data, super.dynamic, super.format);
}

/// Y-axis cylinder or truncated cone, with separate cap normals and UV seams.
class CylinderGeometry extends _ProceduralGeometry {
  factory CylinderGeometry({
    double radiusTop = 1,
    double radiusBottom = 1,
    double height = 1,
    int radialSegments = 32,
    int heightSegments = 1,
    bool openEnded = false,
    double thetaStart = 0,
    double thetaLength = _tau,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) => CylinderGeometry._(
    _cylinder(
      radiusTop,
      radiusBottom,
      height,
      radialSegments,
      heightSegments,
      openEnded,
      thetaStart,
      thetaLength,
      indexFormat,
    ),
    dynamic,
    indexFormat,
  );
  CylinderGeometry._(super.data, super.dynamic, super.format);
}

class ConeGeometry extends _ProceduralGeometry {
  factory ConeGeometry({
    double radius = 1,
    double height = 1,
    int radialSegments = 32,
    int heightSegments = 1,
    bool openEnded = false,
    double thetaStart = 0,
    double thetaLength = _tau,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) => ConeGeometry._(
    _cylinder(
      0,
      radius,
      height,
      radialSegments,
      heightSegments,
      openEnded,
      thetaStart,
      thetaLength,
      indexFormat,
    ),
    dynamic,
    indexFormat,
  );
  ConeGeometry._(super.data, super.dynamic, super.format);
}

_Surface _cylinder(
  double top,
  double bottom,
  double height,
  int columns,
  int rows,
  bool open,
  double start,
  double arc,
  IndexFormat format,
) {
  _positive(top, 'radiusTop', zero: true);
  _positive(bottom, 'radiusBottom', zero: true);
  _positive(height, 'height');
  if (top == 0 && bottom == 0) {
    throw ArgumentError('At least one radius must be positive.');
  }
  _segments(columns, 3);
  _segments(rows, 1);
  _arc(start, arc);
  _budget(
    (columns + 1) * (rows + 1) + (open ? 0 : 2 * (columns + 2)),
    columns * rows * 6 + (open ? 0 : columns * 6),
    format,
  );
  final data = _Surface();
  for (var row = 0; row <= rows; row++) {
    final v = row / rows, r = top + (bottom - top) * v, y = height * (.5 - v);
    for (var i = 0; i <= columns; i++) {
      final u = i / columns,
          t = start + arc * u,
          x = math.cos(t),
          z = math.sin(t);
      data.add(
        Vec3(r * x, y, r * z),
        Vec3(x, (bottom - top) / height, z).normalized(),
        u,
        v,
      );
    }
  }
  data.grid(columns, rows);
  if (!open) {
    for (final (radius, sign) in [(top, 1.0), (bottom, -1.0)]) {
      if (radius == 0) continue;
      final y = sign * height * .5,
          n = Vec3(0, sign, 0),
          center = data.add(Vec3(0, y, 0), n, .5, .5);
      for (var i = 0; i <= columns; i++) {
        final t = start + arc * i / columns, x = math.cos(t), z = math.sin(t);
        final vertex = data.add(
          Vec3(radius * x, y, radius * z),
          n,
          x * .5 + .5,
          z * .5 + .5,
        );
        if (i > 0) {
          if (sign > 0) {
            data.triangle(center, vertex, vertex - 1);
          } else {
            data.triangle(center, vertex - 1, vertex);
          }
        }
      }
    }
  }
  return data;
}

/// A torus around the Z axis. Arc cuts the major circle without adding end caps.
class TorusGeometry extends _ProceduralGeometry {
  factory TorusGeometry({
    double radius = 1,
    double tube = .4,
    int radialSegments = 12,
    int tubularSegments = 48,
    double arc = _tau,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    _positive(radius, 'radius');
    _positive(tube, 'tube');
    _segments(radialSegments, 3);
    _segments(tubularSegments, 3);
    _arc(0, arc);
    _budget(
      (radialSegments + 1) * (tubularSegments + 1),
      radialSegments * tubularSegments * 6,
      indexFormat,
    );
    final data = _Surface();
    for (var j = 0; j <= radialSegments; j++) {
      final v = j / radialSegments,
          phi = v * _tau,
          c = math.cos(phi),
          s = math.sin(phi);
      for (var i = 0; i <= tubularSegments; i++) {
        final u = i / tubularSegments,
            t = u * arc,
            x = math.cos(t),
            y = math.sin(t);
        data.add(
          Vec3((radius + tube * c) * x, (radius + tube * c) * y, tube * s),
          Vec3(c * x, c * y, s),
          u,
          v,
        );
      }
    }
    data.grid(tubularSegments, radialSegments);
    return TorusGeometry._(data, dynamic, indexFormat);
  }
  TorusGeometry._(super.data, super.dynamic, super.format);
}

/// Revolves (radius, height) points around Y. Order the profile bottom to top.
class LatheGeometry extends _ProceduralGeometry {
  factory LatheGeometry(
    Iterable<Vec2> points, {
    int segments = 32,
    double phiStart = 0,
    double phiLength = _tau,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) => LatheGeometry._(
    _lathe(points, segments, phiStart, phiLength, indexFormat),
    dynamic,
    indexFormat,
  );
  LatheGeometry._(super.data, super.dynamic, super.format);
}

_Surface _lathe(
  Iterable<Vec2> input,
  int columns,
  double start,
  double arc,
  IndexFormat format, {
  Vec2 Function(Vec2)? normalForPoint,
}) {
  _segments(columns, 3);
  _arc(start, arc);
  final points = <Vec2>[];
  for (final point in input) {
    if (!point.isFinite ||
        point.x < 0 ||
        (points.isNotEmpty && point == points.last)) {
      throw ArgumentError(
        'Lathe points must be finite, nonnegative in radius and distinct from their neighbor.',
      );
    }
    points.add(point);
    _budget(
      points.length * (columns + 1),
      math.max(0, points.length - 1) * columns * 6,
      format,
    );
  }
  if (points.length < 2 || points.every((p) => p.x == 0)) {
    throw ArgumentError('A lathe needs two points and a nonzero radius.');
  }
  final data = _Surface();
  for (var j = 0; j < points.length; j++) {
    final p = points[j];
    final tangent = j == 0
        ? points[1] - p
        : j == points.length - 1
        ? p - points[j - 1]
        : points[j + 1] - points[j - 1];
    final n =
        normalForPoint?.call(p) ?? Vec2(tangent.y, -tangent.x).normalized();
    for (var i = 0; i <= columns; i++) {
      final u = i / columns,
          t = start + arc * u,
          x = math.cos(t),
          z = math.sin(t);
      data.add(
        Vec3(p.x * x, p.y, p.x * z),
        Vec3(n.x * x, n.y, n.x * z),
        u,
        1 - j / (points.length - 1),
      );
    }
  }
  data.grid(columns, points.length - 1, reverse: true);
  return data;
}

/// Y-axis capsule. Length measures the straight section between hemispheres.
class CapsuleGeometry extends _ProceduralGeometry {
  factory CapsuleGeometry({
    double radius = 1,
    double length = 1,
    int capSegments = 8,
    int radialSegments = 32,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    _positive(radius, 'radius');
    _positive(length, 'length', zero: true);
    _segments(capSegments, 2);
    _segments(radialSegments, 3);
    _budget(
      (capSegments * 2 + 2) * (radialSegments + 1),
      (capSegments * 2 + 1) * radialSegments * 6,
      indexFormat,
    );
    final points = <Vec2>[];
    for (var i = 0; i <= capSegments; i++) {
      final a = -math.pi / 2 + i / capSegments * math.pi / 2;
      points.add(
        Vec2(
          i == 0 ? 0 : radius * math.cos(a),
          -length * .5 + radius * math.sin(a),
        ),
      );
    }
    for (var i = length == 0 ? 1 : 0; i <= capSegments; i++) {
      final a = i / capSegments * math.pi / 2;
      points.add(
        Vec2(
          i == capSegments ? 0 : radius * math.cos(a),
          length * .5 + radius * math.sin(a),
        ),
      );
    }
    return CapsuleGeometry._(
      _lathe(
        points,
        radialSegments,
        0,
        _tau,
        indexFormat,
        normalForPoint: (p) =>
            Vec2(p.x, p.y - p.y.clamp(-length * .5, length * .5)).normalized(),
      ),
      dynamic,
      indexFormat,
    );
  }
  CapsuleGeometry._(super.data, super.dynamic, super.format);
}

/// Sweeps a circle along a path with parallel-transported frames.
/// Closed paths distribute frame twist around the loop to join the seam.
class TubeGeometry extends _ProceduralGeometry {
  factory TubeGeometry(
    Curve3 path, {
    double radius = 1,
    int tubularSegments = 64,
    int radialSegments = 8,
    bool closed = false,
    bool spaced = true,
    int arcLengthDivisions = 200,
    bool dynamic = false,
    IndexFormat indexFormat = IndexFormat.uint32,
  }) {
    _positive(radius, 'radius');
    _segments(tubularSegments, 1);
    _segments(radialSegments, 3);
    _segments(arcLengthDivisions, 1);
    _budget(
      (tubularSegments + 1) * (radialSegments + 1),
      tubularSegments * radialSegments * 6,
      indexFormat,
    );
    final table = spaced ? path.sample(divisions: arcLengthDivisions) : null;
    final centers = <Vec3>[], tangents = <Vec3>[], normals = <Vec3>[];
    for (var i = 0; i <= tubularSegments; i++) {
      final u = i / tubularSegments, t = table?.parameterAt(u) ?? u;
      final p = path.pointAt(t), direction = path.tangentAt(t).normalized();
      if (!p.isFinite) {
        throw ArgumentError('Tube path positions must be finite.');
      }
      centers.add(p);
      tangents.add(direction);
    }
    if (closed &&
        (centers.first.distanceTo(centers.last) > 1e-6 ||
            tangents.first.dot(tangents.last) < .99999)) {
      throw ArgumentError(
        'A closed tube needs matching end positions and tangent directions.',
      );
    }
    final first = tangents.first;
    final axis =
        first.x.abs() <= first.y.abs() && first.x.abs() <= first.z.abs()
        ? const Vec3(1, 0, 0)
        : first.y.abs() <= first.z.abs()
        ? const Vec3(0, 1, 0)
        : const Vec3(0, 0, 1);
    normals.add(first.cross(axis).normalized());
    for (var i = 1; i <= tubularSegments; i++) {
      final previous = tangents[i - 1],
          current = tangents[i],
          rotation = previous.cross(current);
      final dot = previous.dot(current).clamp(-1.0, 1.0);
      if (dot < -.999999) {
        throw ArgumentError('Tube path reverses direction at a cusp.');
      }
      var normal = normals.last;
      if (rotation.length > 1e-12) {
        normal = Quat.axisAngle(
          rotation,
          math.atan2(rotation.length, dot),
        ).rotate(normal);
      }
      normals.add((normal - current * normal.dot(current)).normalized());
    }
    if (closed) {
      final twist = math.atan2(
        first.dot(normals.last.cross(normals.first)),
        normals.last.dot(normals.first),
      );
      for (var i = 1; i <= tubularSegments; i++) {
        normals[i] = Quat.axisAngle(
          tangents[i],
          twist * i / tubularSegments,
        ).rotate(normals[i]);
      }
    }
    final data = _Surface();
    for (var j = 0; j <= tubularSegments; j++) {
      final normal = normals[j],
          binormal = tangents[j].cross(normal).normalized();
      for (var i = 0; i <= radialSegments; i++) {
        final angle = _tau * i / radialSegments,
            n = normal * math.cos(angle) + binormal * math.sin(angle);
        data.add(
          centers[j] + n * radius,
          n,
          i / radialSegments,
          j / tubularSegments,
        );
      }
    }
    data.grid(radialSegments, tubularSegments);
    return TubeGeometry._(data, dynamic, indexFormat);
  }
  TubeGeometry._(super.data, super.dynamic, super.format);
}
