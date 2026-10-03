import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test(
    'fixed charts blend continuously with analytic weight derivatives at seams and poles',
    () {
      for (final ellipsoid in [Ellipsoid.wgs84, Ellipsoid(3, 2, 1)]) {
        final charts = OceanWaveCharts(ellipsoid: ellipsoid, seed: 42);
        Vec3 project(Vec3 p) =>
            p /
            math.sqrt(
              p.x * p.x / (ellipsoid.x * ellipsoid.x) +
                  p.y * p.y / (ellipsoid.y * ellipsoid.y) +
                  p.z * p.z / (ellipsoid.z * ellipsoid.z),
            );
        final scale = ellipsoid.minimumRadius * .02;
        OceanChartValue value(OceanChartCoordinate c) => OceanChartValue(
          math.sin(c.u / scale) + .3 * math.cos(c.v / scale),
          math.cos(c.u / scale) / scale,
          -.3 * math.sin(c.v / scale) / scale,
        );
        for (final direction in [
          const Vec3(1, 0, 0),
          const Vec3(1, 1, 0),
          const Vec3(1, 1, 1),
          const Vec3(0, 0, 1),
          const Vec3(.000000001, 0, 1),
          const Vec3(-1, -1, -1),
        ]) {
          final p = project(direction),
              at = charts.atSurface(p),
              blended = at.blend(value),
              epsilon = ellipsoid.minimumRadius * 1e-7;
          expect(
            at.coordinates.fold(0.0, (v, c) => v + c.weight),
            closeTo(1, 1e-14),
          );
          expect(
            at.coordinates.fold(0.0, (v, c) => v + c.weightEast),
            closeTo(0, 1e-12),
          );
          for (final (axis, slope) in [
            (at.east, blended.eastDerivative),
            (at.north, blended.northDerivative),
          ]) {
            final plus = charts
                .atSurface(project(p + axis * epsilon))
                .blend(value)
                .value;
            final minus = charts
                .atSurface(project(p - axis * epsilon))
                .blend(value)
                .value;
            expect(
              (plus - minus) / (2 * epsilon),
              closeTo(slope, 2e-7 / math.max(1, ellipsoid.minimumRadius)),
            );
          }
          // No camera, patch origin, local rebase or visual grid enters chart identity.
          final repeat = OceanWaveCharts(
            ellipsoid: ellipsoid,
            seed: 42,
          ).atSurface(p);
          expect(
            repeat.coordinates.map((c) => (c.id, c.seed, c.u, c.v, c.weight)),
            at.coordinates.map((c) => (c.id, c.seed, c.u, c.v, c.weight)),
          );
        }
        expect(
          () => charts.atSurface(const Vec3(0, 0, 0)),
          throwsArgumentError,
        );
        expect(
          () => charts.atSurface(const Vec3(1e10, 0, 0)),
          throwsArgumentError,
        );
      }
    },
  );
  test(
    'physics leases keep charts resident off camera and admission is atomic',
    () {
      final residency = OceanChartResidency(maxCharts: 3);
      residency.setVisible([0, 2]);
      final lease = residency.acquirePhysics([1, 2]);
      expect(residency.residentIds, {0, 1, 2});
      expect(() => residency.setVisible([3, 4]), throwsStateError);
      expect(residency.residentIds, {0, 1, 2});
      residency.setVisible([3]);
      expect(residency.residentIds, {1, 2, 3});
      lease.close();
      lease.close();
      expect(residency.residentIds, {3});
      expect(() => residency.acquirePhysics([9]), throwsArgumentError);
    },
  );
}
