import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'geodesy.dart';

/// Z-up ECEF mesh. Normals follow the ellipsoid gradient, including flattening.
class EllipsoidGeometry extends BufferGeometry {
  factory EllipsoidGeometry({
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
    int longitudeSegments = 96,
    int latitudeSegments = 48,
  }) {
    if (longitudeSegments < 3 ||
        latitudeSegments < 2 ||
        (longitudeSegments + 1) * (latitudeSegments + 1) > 1000000) {
      throw ArgumentError('Invalid ellipsoid segment count.');
    }
    final positions = <double>[], normals = <double>[];
    final indices = <int>[];
    for (var y = 0; y <= latitudeSegments; y++) {
      final phi = y * math.pi / latitudeSegments;
      for (var x = 0; x <= longitudeSegments; x++) {
        final theta = (x / longitudeSegments - .5) * 2 * math.pi;
        final p = Vec3(
          ellipsoid.x * math.cos(theta) * math.sin(phi),
          ellipsoid.y * math.sin(theta) * math.sin(phi),
          ellipsoid.z * math.cos(phi),
        );
        positions.addAll(p.storage);
        normals.addAll(ellipsoid.surfaceNormal(p).storage);
      }
    }
    for (var y = 0; y < latitudeSegments; y++) {
      for (var x = 0; x < longitudeSegments; x++) {
        final b = y * (longitudeSegments + 1) + x,
            a = b + 1,
            c = b + longitudeSegments + 1,
            d = c + 1;
        if (y != 0) indices.addAll([a, b, d]);
        if (y != latitudeSegments - 1) indices.addAll([b, c, d]);
      }
    }
    return EllipsoidGeometry._(positions, normals, indices);
  }
  EllipsoidGeometry._(List<double> p, List<double> n, List<int> i)
    : super(positions: p, normals: n, indices: i);
}
