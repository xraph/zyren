import 'dart:math' as math;
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test('WGS84 anchors match equator, prime meridian and pole', () {
    expect(
      Geodetic.degrees(0, 0).toEcef().distanceTo(Vec3(6378137, 0, 0)),
      lessThan(1e-8),
    );
    expect(
      Geodetic.degrees(90, 0).toEcef().distanceTo(Vec3(0, 6378137, 0)),
      lessThan(1e-8),
    );
    expect(
      Geodetic.degrees(0, 90).toEcef().z,
      closeTo(6356752.3142451793, 1e-8),
    );
  });
  test('geodetic round trips include dateline, poles and negative height', () {
    for (final ellipsoid in [
      Ellipsoid.wgs84,
      Ellipsoid(7000000, 6500000, 6000000),
    ]) {
      for (final lon in [-180.0, -87.6298, 0.0, 139.6917, 179.999]) {
        for (final lat in [-90.0, -70.0, 0.0, 41.8781, 90.0]) {
          for (final height in [-500.0, 0.0, 400000.0, 36000000.0]) {
            final source = Geodetic.degrees(lon, lat, height);
            final actual = ellipsoid.fromEcef(
              source.toEcef(ellipsoid: ellipsoid),
            );
            expect(actual.latitude, closeTo(source.latitude, 1e-10));
            expect(actual.height, closeTo(height, 1e-5));
            expect(
              actual
                  .toEcef(ellipsoid: ellipsoid)
                  .distanceTo(source.toEcef(ellipsoid: ellipsoid)),
              lessThan(1e-5),
            );
          }
        }
      }
    }
  });
  test('ENU remains orthonormal at both poles and preserves millimetres', () {
    for (final latitude in [-90.0, 0.0, 90.0]) {
      final frame = EastNorthUpFrame(Geodetic.degrees(27, latitude, 123));
      expect(
        frame.east.cross(frame.north).distanceTo(frame.up),
        lessThan(1e-12),
      );
      final local = Vec3(.001, 25, -3);
      expect(
        frame.toLocal(frame.toEcef(local)).distanceTo(local),
        lessThan(1e-8),
      );
    }
  });
  test('ray intersection handles outside, inside, tangent and miss', () {
    final sphere = Ellipsoid(2, 2, 2);
    expect(
      sphere.intersectRay(Vec3(5, 0, 0), Vec3(-2, 0, 0))!.x,
      closeTo(2, 1e-12),
    );
    expect(sphere.intersectRay(Vec3.zero, Vec3(3, 0, 0))!.x, closeTo(2, 1e-12));
    expect(
      sphere
          .intersectRay(Vec3(2, -4, 0), Vec3(0, 1, 0))!
          .distanceTo(Vec3(2, 0, 0)),
      lessThan(1e-12),
    );
    expect(sphere.intersectRay(Vec3(3, 0, 0), Vec3(1, 0, 0)), isNull);
    expect(() => sphere.fromEcef(Vec3.zero), throwsArgumentError);
    expect(() => Geodetic(0, math.pi), throwsArgumentError);
  });
  test('flattened ellipsoid normals match its gradient', () {
    final ellipsoid = Ellipsoid(4, 3, 2);
    final mesh = EllipsoidGeometry(
      ellipsoid: ellipsoid,
      longitudeSegments: 12,
      latitudeSegments: 6,
    );
    for (var i = 0; i < mesh.positions.length; i += 3) {
      final p = Vec3.array(mesh.positions, i), n = Vec3.array(mesh.normals, i);
      // Vertex storage is float32. Geodetic calculations above remain float64.
      expect(n.distanceTo(ellipsoid.surfaceNormal(p)), lessThan(1e-7));
    }
    for (var i = 0; i < mesh.indices.length; i += 3) {
      Vec3 vertex(int index) =>
          Vec3.array(mesh.positions, mesh.indices[index] * 3);
      final a = vertex(i), b = vertex(i + 1), c = vertex(i + 2);
      expect((b - a).cross(c - a).dot(a), greaterThan(0));
    }
  });
}
