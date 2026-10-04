import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

List<OceanCanonicalSnapshot> fields(double amplitude, {double chop = 1}) => [
  for (var id = 0; id < 6; id++)
    OceanCanonicalField(
      OceanSeaState(
        seed: OceanWaveCharts(seed: 42).seedFor(id),
        canonicalResolution: 8,
        bands: [
          OceanWaveBand(
            patchMetres: 64,
            minWaveNumber: 0,
            maxWaveNumber: .5,
            windSpeed: 12,
            windHeadingRadians: .3,
            amplitude: amplitude,
            choppiness: chop,
          ),
        ],
      ),
      maxModes: 64,
    ).at(1.3),
];
void main() {
  test(
    'strict contraction accepts bounded seas and rejects an unproved rough surface',
    () {
      for (final (amplitude, chop, admitted) in [
        (.0002, 1.0, true),
        (.002, 1.0, true),
        (.02, .3, true),
        (.02, 1.0, false),
      ]) {
        final snapshots = fields(amplitude, chop: chop),
            bounds = OceanSurfaceBounds(
              ellipsoid: Ellipsoid.wgs84,
              meanLevel: 0,
              charts: snapshots.map((s) => s.envelope).toList(),
            );
        expect(bounds.admissible, admitted);
        if (admitted) expect(bounds.horizontalContraction, lessThan(.8));
      }
      expect(
        () => OceanQueryPolicy(maxAge: const Duration(days: 2)),
        throwsArgumentError,
      );
      expect(
        () => OceanQueryPolicy(maxHeightErrorMetres: double.nan),
        throwsArgumentError,
      );
    },
  );
  test(
    'field gradient envelopes bound independently sampled world derivatives and velocity',
    () {
      final snapshots = fields(.002),
          charts = OceanWaveCharts(seed: 42),
          e = Ellipsoid.wgs84;
      final bounds = OceanSurfaceBounds(
        ellipsoid: e,
        meanLevel: 0,
        charts: snapshots.map((s) => s.envelope).toList(),
      );
      final random = math.Random(51);
      for (var i = 0; i < 80; i++) {
        final point = charts.atSurface(
          e.toEcef(
            Geodetic(
              random.nextDouble() * 6 - 3,
              random.nextDouble() * 3 - 1.5,
            ),
          ),
        );
        final surface = blendOceanSurface(
          point,
          (c) => snapshots[c.id].sample(c.u, c.v),
        );
        expect(
          (surface.eastDerivative - point.east).length,
          lessThan(bounds.displacementGradient),
        );
        expect(
          (surface.northDerivative - point.north).length,
          lessThan(bounds.displacementGradient),
        );
        final accuracy = bounds.assess(
          residual: 1e-8,
          materialDistance: 0,
          eastDerivative: surface.eastDerivative,
          northDerivative: surface.northDerivative,
          fieldErrors: [
            for (final _ in point.coordinates)
              const OceanFieldError(1e-7, 1e-7, 1e-8, 1e-8, 1e-7),
          ],
        );
        expect(accuracy, isNotNull);
        expect(accuracy!.heightErrorMetres, lessThan(.01));
        expect(accuracy.normalErrorRadians, lessThan(math.pi / 360));
        expect(
          bounds.assess(
            residual: 1,
            materialDistance: bounds.radius,
            eastDerivative: surface.eastDerivative,
            northDerivative: surface.northDerivative,
            fieldErrors: [const OceanFieldError(0, 0, 0, 0, 0)],
          ),
          isNull,
        );
      }
    },
  );
}
