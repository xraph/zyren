import '../math/mat4.dart';
import '../math/vec3.dart';
import '../scene/scene.dart';
import 'bounds.dart';

/// Immutable native clip volume: X/Y in [-W, W], Z in [0, W].
final class Frustum {
  final Vec3 _origin;
  final List<(Vec3, double)> _planes;

  /// [matrix] transforms coordinates relative to [origin] into clip space.
  /// Bounds and points passed to this frustum remain in world coordinates.
  Frustum.fromMatrix(Mat4 matrix, {Vec3 origin = Vec3.zero})
    : _origin = origin,
      _planes = _extract(matrix) {
    if (!origin.isFinite) throw ArgumentError('Frustum origin must be finite.');
  }

  factory Frustum.fromCamera(Camera camera, double aspect) =>
      Frustum.fromMatrix(
        camera.viewProjection(aspect),
        origin: camera.position,
      );

  static List<(Vec3, double)> _extract(Mat4 matrix) {
    final m = matrix.storage;
    List<double> row(int r) => [for (var c = 0; c < 4; c++) m[c * 4 + r]];
    final x = row(0), y = row(1), z = row(2), w = row(3);
    List<double> combine(List<double> a, List<double> b, double sign) => [
      for (var i = 0; i < 4; i++) a[i] + sign * b[i],
    ];
    return List.unmodifiable([
      for (final values in [
        combine(w, x, 1),
        combine(w, x, -1),
        combine(w, y, 1),
        combine(w, y, -1),
        z,
        combine(w, z, -1),
      ])
        _plane(values),
    ]);
  }

  static (Vec3, double) _plane(List<double> values) {
    final normal = Vec3(values[0], values[1], values[2]);
    final length = normal.length;
    if (!length.isFinite || length == 0 || !values[3].isFinite) {
      throw ArgumentError('Frustum matrix must define six finite planes.');
    }
    final constant = values[3] / length;
    if (!constant.isFinite) throw ArgumentError('Frustum plane is not finite.');
    return (normal * (1 / length), constant);
  }

  bool _outside(Vec3 normal, double constant, Vec3 point) {
    final x = normal.x * point.x,
        y = normal.y * point.y,
        z = normal.z * point.z;
    // Keep boundary objects when float32 GPU transforms round differently.
    final tolerance = 1e-6 * (1 + x.abs() + y.abs() + z.abs() + constant.abs());
    return x + y + z + constant < -tolerance;
  }

  bool containsPoint(Vec3 point) {
    if (!point.isFinite) throw ArgumentError('Frustum point must be finite.');
    final relative = point - _origin;
    return !_planes.any((p) => _outside(p.$1, p.$2, relative));
  }

  /// Unknown bounds stay visible; empty bounds contain no drawable surface.
  bool intersectsBounds(Bounds3? bounds) {
    if (bounds == null) return true;
    if (bounds.isEmpty) return false;
    final low = bounds.minimum - _origin, high = bounds.maximum - _origin;
    for (final (normal, constant) in _planes) {
      final point = Vec3(
        normal.x >= 0 ? high.x : low.x,
        normal.y >= 0 ? high.y : low.y,
        normal.z >= 0 ? high.z : low.z,
      );
      if (_outside(normal, constant, point)) return false;
    }
    return true;
  }
}
