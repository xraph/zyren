import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test(
    'patch bounds and chart requests cover interior extrema and displacement',
    () {
      final random = math.Random(91);
      for (final ellipsoid in [
        Ellipsoid.wgs84,
        Ellipsoid(3, 2, 1),
        Ellipsoid(1, 100, 2),
      ]) {
        final charts = OceanWaveCharts(ellipsoid: ellipsoid, seed: 19);
        for (var k = 0; k < 120; k++) {
          final level = random.nextInt(12), n = 1 << level;
          final p = OceanPatchId(
            face: k % 6,
            level: level,
            x: random.nextInt(n),
            y: random.nextInt(n),
          );
          final displacement = .01 * ellipsoid.minimumRadius,
              b = p.bounds(ellipsoid, displacementBoundMetres: displacement),
              ids = charts.chartsForPatch(p);
          for (var j = 0; j <= 8; j++) {
            for (var i = 0; i <= 8; i++) {
              final point = p.point(i / 8, j / 8, ellipsoid);
              expect(
                point.distanceTo(b.center) + displacement,
                lessThanOrEqualTo(b.radius + 1e-7),
              );
              expect(
                ids.containsAll(
                  charts.atSurface(point).coordinates.map((c) => c.id),
                ),
                isTrue,
              );
            }
          }
        }
      }
    },
  );
  test(
    'displacement, numeric range and physical-pixel budgets fail explicitly',
    () {
      final p = OceanPatchId(face: 0, level: 0, x: 0, y: 0);
      expect(
        () => p.bounds(Ellipsoid.wgs84, displacementBoundMetres: 1e6),
        throwsArgumentError,
      );
      expect(
        () => p.point(.5, .5, Ellipsoid(1e200, 1e200, 1e200)),
        throwsArgumentError,
      );
      expect(
        () => OceanLodSettings(
          maxScreenError: 1,
          maxPatches: 6,
          maxVertices: 100,
          segments: 7,
        ),
        throwsArgumentError,
      );
      final settings = OceanLodSettings(
        maxScreenError: 1,
        maxPatches: 6,
        maxVertices: 6 * 81,
        segments: 8,
      );
      final camera = PerspectiveCamera(
        position: const Vec3(2e7, 0, 0),
        up: const Vec3(0, 0, 1),
        far: 4e7,
      );
      final a = selectOceanSurface(
        camera,
        const ViewportMetrics(800, 600),
        Ellipsoid.wgs84,
        settings,
      );
      final b = selectOceanSurface(
        camera,
        const ViewportMetrics(800, 600, devicePixelRatio: 2),
        Ellipsoid.wgs84,
        settings,
      );
      expect(b.maximumScreenError, closeTo(2 * a.maximumScreenError, 1e-9));
      expect(
        () => selectOceanSurface(
          camera,
          const ViewportMetrics(800, 600, devicePixelRatio: double.nan),
          Ellipsoid.wgs84,
          settings,
        ),
        throwsArgumentError,
      );
    },
  );
}
