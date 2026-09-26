import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';

/// Longitude and latitude in radians; height in metres above the ellipsoid.
class Geodetic {
  final double longitude, latitude, height;
  Geodetic(double longitude, this.latitude, [this.height = 0])
    : longitude = (longitude + math.pi) % (2 * math.pi) - math.pi {
    if (!longitude.isFinite ||
        !latitude.isFinite ||
        !height.isFinite ||
        latitude.abs() > math.pi / 2) {
      throw ArgumentError(
        'Geodetic coordinates must be finite, with latitude in [-pi/2, pi/2].',
      );
    }
  }
  factory Geodetic.degrees(
    double longitude,
    double latitude, [
    double height = 0,
  ]) => Geodetic(longitude * math.pi / 180, latitude * math.pi / 180, height);
  double get longitudeDegrees => longitude * 180 / math.pi;
  double get latitudeDegrees => latitude * 180 / math.pi;
  Vec3 toEcef({Ellipsoid ellipsoid = Ellipsoid.wgs84}) =>
      ellipsoid.toEcef(this);
}

/// A triaxial ellipsoid with positive radii in metres.
class Ellipsoid {
  final double x, y, z;
  static const wgs84 = Ellipsoid._(6378137, 6378137, 6356752.3142451793);
  const Ellipsoid._(this.x, this.y, this.z);
  factory Ellipsoid(double x, double y, double z) {
    if ([x, y, z].any((v) => !v.isFinite || v <= 0)) {
      throw ArgumentError('Ellipsoid radii must be positive.');
    }
    return Ellipsoid._(x, y, z);
  }
  Vec3 toEcef(Geodetic coordinate) {
    final c = math.cos(coordinate.latitude);
    final normal = Vec3(
      c * math.cos(coordinate.longitude),
      c * math.sin(coordinate.longitude),
      math.sin(coordinate.latitude),
    );
    var point = Vec3(x * x * normal.x, y * y * normal.y, z * z * normal.z);
    point = point / math.sqrt(normal.dot(point));
    return point + normal * coordinate.height;
  }

  /// Bounded Newton projection. Near-centre positions have no reliable inverse.
  Vec3 projectOnSurface(Vec3 position) {
    _finite(position);
    final inverse = Vec3(1 / (x * x), 1 / (y * y), 1 / (z * z));
    final squares = Vec3(
      position.x * position.x * inverse.x,
      position.y * position.y * inverse.y,
      position.z * position.z * inverse.z,
    );
    final norm = squares.x + squares.y + squares.z;
    if (!norm.isFinite || norm < .1) {
      throw ArgumentError(
        'Geodetic projection is undefined near the ellipsoid centre.',
      );
    }
    final ratio = math.sqrt(1 / norm);
    final gradient = Vec3(
      position.x * ratio * inverse.x,
      position.y * ratio * inverse.y,
      position.z * ratio * inverse.z,
    );
    var lambda = (1 - ratio) * position.length / gradient.length;
    for (var iteration = 0; iteration < 64; iteration++) {
      final sx = 1 / (1 + lambda * inverse.x),
          sy = 1 / (1 + lambda * inverse.y),
          sz = 1 / (1 + lambda * inverse.z);
      final error =
          squares.x * sx * sx + squares.y * sy * sy + squares.z * sz * sz - 1;
      if (error.abs() < 1e-13) {
        return Vec3(position.x * sx, position.y * sy, position.z * sz);
      }
      final derivative =
          -2 *
          (squares.x * sx * sx * sx * inverse.x +
              squares.y * sy * sy * sy * inverse.y +
              squares.z * sz * sz * sz * inverse.z);
      lambda -= error / derivative;
      if (!lambda.isFinite) break;
    }
    throw StateError('Ellipsoid projection did not converge.');
  }

  Vec3 surfaceNormal(Vec3 position) {
    _finite(position);
    final normal = Vec3(
      position.x / (x * x),
      position.y / (y * y),
      position.z / (z * z),
    );
    if (normal.length2 == 0) {
      throw ArgumentError('The centre has no surface normal.');
    }
    return normal.normalized();
  }

  Geodetic fromEcef(Vec3 position) {
    final surface = projectOnSurface(position);
    final normal = surfaceNormal(surface), difference = position - surface;
    final height = difference.length * (difference.dot(position) < 0 ? -1 : 1);
    return Geodetic(
      math.atan2(normal.y, normal.x),
      math.atan2(
        normal.z,
        math.sqrt(normal.x * normal.x + normal.y * normal.y),
      ),
      height,
    );
  }

  /// Nearest forward ray intersection. Directions need not be normalized.
  Vec3? intersectRay(Vec3 origin, Vec3 direction) {
    _finite(origin);
    _finite(direction);
    final p = Vec3(origin.x / x, origin.y / y, origin.z / z),
        d = Vec3(direction.x / x, direction.y / y, direction.z / z);
    final a = d.length2, b = p.dot(d), c = p.length2 - 1;
    if (a == 0) throw ArgumentError('Ray direction must be nonzero.');
    if (c == 0) return origin;
    final discriminant = b * b - a * c;
    if (discriminant < 0) return null;
    final q = -b - (b < 0 ? -1 : 1) * math.sqrt(discriminant);
    if (q == 0) return null;
    final first = q / a, second = c / q;
    final near = math.min(first, second), far = math.max(first, second);
    if (far < 0) return null;
    return origin + direction * (near >= 0 ? near : far);
  }
}

/// East/north/up frame with a double precision ECEF origin, including at poles.
class EastNorthUpFrame {
  final Vec3 _origin, _east, _north, _up;
  EastNorthUpFrame._(this._origin, this._east, this._north, this._up);
  factory EastNorthUpFrame(
    Geodetic coordinate, {
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
  }) {
    final lon = coordinate.longitude, lat = coordinate.latitude;
    final east = Vec3(-math.sin(lon), math.cos(lon), 0);
    final up = Vec3(
      math.cos(lat) * math.cos(lon),
      math.cos(lat) * math.sin(lon),
      math.sin(lat),
    );
    return EastNorthUpFrame._(
      coordinate.toEcef(ellipsoid: ellipsoid),
      east,
      up.cross(east),
      up,
    );
  }
  Vec3 get origin => _origin;
  Vec3 get east => _east;
  Vec3 get north => _north;
  Vec3 get up => _up;
  Vec3 toLocal(Vec3 ecef) {
    _finite(ecef);
    final relative = ecef - _origin;
    return Vec3(relative.dot(_east), relative.dot(_north), relative.dot(_up));
  }

  Vec3 toEcef(Vec3 local) {
    _finite(local);
    return _origin + _east * local.x + _north * local.y + _up * local.z;
  }

  Mat4 get matrix => Mat4([
    _east.x,
    _east.y,
    _east.z,
    0,
    _north.x,
    _north.y,
    _north.z,
    0,
    _up.x,
    _up.y,
    _up.z,
    0,
    _origin.x,
    _origin.y,
    _origin.z,
    1,
  ]);
}

void _finite(Vec3 vector) {
  if (vector.storage.any((v) => !v.isFinite)) {
    throw ArgumentError('Coordinates must be finite.');
  }
}
