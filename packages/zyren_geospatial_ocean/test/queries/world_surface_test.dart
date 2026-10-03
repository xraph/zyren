import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

OceanReferenceSample field(OceanChartCoordinate c) => OceanReferenceSample(
  height: 2 + math.sin(c.u / 9) + .2 * math.cos(c.v / 7),
  displacementX: .3 * math.cos(c.u / 9),
  displacementZ: .1 * math.sin(c.v / 7),
  slopeX: math.cos(c.u / 9) / 9,
  slopeZ: -.2 * math.sin(c.v / 7) / 7,
  velocityX: .5,
  velocityY: .2,
  velocityZ: -.1,
  displacementXX: -.3 * math.sin(c.u / 9) / 9,
  displacementXZ: 0,
  displacementZX: 0,
  displacementZZ: .1 * math.cos(c.v / 7) / 7,
);
void main() {
  test(
    'ellipsoid normal footpoints retain height and reject the ambiguous interior',
    () {
      for (final e in [Ellipsoid.wgs84, Ellipsoid(30, 20, 10)]) {
        for (final lon in [0.0, 1.2, 3.14]) {
          for (final lat in [-math.pi / 2, -.4, 0.0, .7, math.pi / 2]) {
            for (final height in [-.001, 0.0, 10.0, 10000.0]) {
              final point = e.toEcef(Geodetic(lon, lat, height));
              final foot = oceanEllipsoidFootpoint(point, e);
              expect(
                foot.position.distanceTo(e.toEcef(Geodetic(lon, lat))),
                lessThan(1e-6),
              );
              expect(foot.height, closeTo(height, 1e-6));
            }
          }
        }
      }
      expect(
        () => oceanEllipsoidFootpoint(Vec3.zero, Ellipsoid.wgs84),
        throwsArgumentError,
      );
      expect(
        () =>
            oceanEllipsoidFootpoint(const Vec3(1, 0, 0), Ellipsoid(30, 20, 10)),
        throwsArgumentError,
      );
    },
  );
  test(
    'world surface includes changing blend weights and tangent projection derivatives',
    () {
      final e = Ellipsoid(300, 200, 100),
          charts = OceanWaveCharts(ellipsoid: e, seed: 42);
      Vec3 project(Vec3 p) =>
          p /
          math.sqrt(
            p.x * p.x / (e.x * e.x) +
                p.y * p.y / (e.y * e.y) +
                p.z * p.z / (e.z * e.z),
          );
      for (final direction in [
        const Vec3(1, 1, 1),
        const Vec3(1, 1, 0),
        const Vec3(0, 0, 1),
        const Vec3(1, 0, 0),
      ]) {
        final point = charts.atSurface(project(direction)),
            surface = blendOceanSurface(point, field);
        const delta = 1e-4;
        for (final (axis, derivative) in [
          (point.east, surface.eastDerivative),
          (point.north, surface.northDerivative),
        ]) {
          final plus = blendOceanSurface(
                charts.atSurface(project(point.position + axis * delta)),
                field,
              ),
              minus = blendOceanSurface(
                charts.atSurface(project(point.position - axis * delta)),
                field,
              );
          expect(
            ((plus.position - minus.position) / (2 * delta)).distanceTo(
              derivative,
            ),
            lessThan(1e-7),
          );
        }
        expect(surface.normal.dot(point.normal), greaterThan(.9));
        expect(surface.normal.length, closeTo(1, 1e-12));
      }
    },
  );
}
