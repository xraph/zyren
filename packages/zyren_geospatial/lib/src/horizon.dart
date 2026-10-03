import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'geodesy.dart';

/// Conservative whole-sphere occlusion in ECEF coordinates.
/// Use a lower surface height than the terrain you render. Cameras inside that
/// ellipsoid and bounds well inside it remain visible, including local scenes.
class EllipsoidHorizon {
  final Ellipsoid ellipsoid;
  final double minimumHeight;
  const EllipsoidHorizon({
    this.ellipsoid = Ellipsoid.wgs84,
    this.minimumHeight = -12000,
  });

  bool isSphereVisible(Vec3 camera, Vec3 center, double radius) {
    final x = ellipsoid.x + minimumHeight,
        y = ellipsoid.y + minimumHeight,
        z = ellipsoid.z + minimumHeight;
    if (![x, y, z, radius].every((v) => v.isFinite) ||
        math.min(x, math.min(y, z)) <= 0 ||
        radius < 0) {
      throw ArgumentError(
        'Horizon bounds and ellipsoid must be finite and valid.',
      );
    }
    Vec3 scaled(Vec3 v) => Vec3(v.x / x, v.y / y, v.z / z);
    final eye = scaled(camera), point = scaled(center);
    final r = radius / math.min(x, math.min(y, z));
    final d = eye.length;
    if (!d.isFinite ||
        d <= 1 ||
        !point.length.isFinite ||
        point.length + r < .95) {
      return true;
    }
    // Both the horizon plane and the tangent cone must contain the whole bound.
    // Testing only its centre would wrongly reject tall or horizon-crossing tiles.
    if (eye.dot(point) + d * r >= 1) return true;
    final delta = point - eye, axis = -eye / d;
    final along = delta.dot(axis);
    final across = (delta - axis * along).length;
    final margin = along / d - across * math.sqrt(d * d - 1) / d;
    return margin <= r + 1e-12;
  }
}
