import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

OceanSeaState querySea({double amplitude = .0002, double chop = 1}) =>
    OceanSeaState(
      seed: 42,
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
    );
GeoWorldFrame queryFrame() => GeoWorldFrame(
  reference: const GeospatialReference(),
  origin: Geodetic(0, 0),
);
GeoInstant queryTime() =>
    GeoInstant(tick: 78, hz: 60, epoch: DateTime.utc(2026));

void main() {
  test(
    'world batches recover known displaced material points across seams and poles',
    () async {
      final state = querySea(), frame = queryFrame(), time = queryTime();
      final charts = OceanWaveCharts(seed: state.seed);
      final fields = <OceanCanonicalSnapshot>[];
      for (var id = 0; id < 6; id++) {
        fields.add(
          OceanCanonicalField(
            OceanSeaState(
              seed: charts.seedFor(id),
              canonicalResolution: 8,
              bands: state.bands,
            ),
            maxModes: 64,
          ).at(time.seconds),
        );
      }
      final material = [
        Geodetic(0, 0),
        Geodetic(math.pi / 4, .6),
        Geodetic(-math.pi / 4, -.6),
        Geodetic(math.pi, .2),
        Geodetic(0, math.pi / 2),
        Geodetic(0, -math.pi / 2),
      ];
      final surfaces = [
        for (final g in material)
          blendOceanSurface(
            charts.atSurface(Ellipsoid.wgs84.toEcef(g)),
            (c) => fields[c.id].sample(c.u, c.v),
          ),
      ];
      final sampler = await OceanSamplerCpu.create(
        state: state,
        frame: frame,
        now: () => time,
        coverage: const OceanAllWaterCoverage(),
      );
      try {
        final results = await sampler.sampleBatch([
          for (final s in surfaces) OceanQuery(s.position, time),
        ], OceanQueryPolicy());
        for (var i = 0; i < results.length; i++) {
          final r = results[i], expected = surfaces[i];
          expect(r.failure, isNull, reason: 'point $i');
          expect(r.available, isTrue);
          expect(
            (r.value!.positionEcef - expected.position).length,
            lessThanOrEqualTo(r.accuracy!.heightErrorMetres + 2e-8),
          );
          expect(
            (r.value!.materialEcef - Ellipsoid.wgs84.toEcef(material[i]))
                .length,
            lessThan(1e-5),
          );
          expect(
            (r.value!.normalEcef - expected.normal).length,
            lessThanOrEqualTo(r.accuracy!.normalErrorRadians + 1e-8),
          );
          expect(
            (r.value!.velocityEcef - expected.velocity).length,
            lessThanOrEqualTo(r.accuracy!.velocityErrorMetresPerSecond + 1e-8),
          );
          expect(r.value!.positionLocal, frame.toLocal(r.value!.positionEcef));
          expect(r.seaStateRevision, state.revision);
          expect(r.frameRevision, 0);
          expect(r.evaluatedTime, time);
          expect(r.age, Duration.zero);
        }
        expect(sampler.diagnostics.modeEvaluations, greaterThan(6 * 64));
        expect(sampler.diagnostics.fieldBatches, lessThan(6 * 6 * 5));
      } finally {
        await sampler.close();
        await frame.dispose();
      }
    },
  );

  test(
    'strict accuracy and mode budgets fail with null physical values',
    () async {
      final frame = queryFrame(), time = queryTime();
      final sampler = await OceanSamplerCpu.create(
        state: querySea(amplitude: .02),
        frame: frame,
        now: () => time,
        coverage: const OceanAllWaterCoverage(),
      );
      final queries = [OceanQuery(const Vec3(6378137, 0, 0), time)];
      try {
        final rough = await sampler.sampleBatch(queries, OceanQueryPolicy());
        expect(rough.single.failure, OceanQueryFailure.accuracy);
        expect(rough.single.value, isNull);
        final budget = await sampler.sampleBatch(
          queries,
          OceanQueryPolicy(maxModeEvaluations: 64),
        );
        expect(budget.single.failure, OceanQueryFailure.workBudget);
        expect(budget.single.value, isNull);
      } finally {
        await sampler.close();
        await frame.dispose();
      }
    },
  );
}
