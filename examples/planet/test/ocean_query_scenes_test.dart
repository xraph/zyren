import 'dart:io';
import 'package:test/test.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  final scenes = OceanLabSceneDefinition.decode(
    File('assets/ocean/scenes.json').readAsStringSync(),
  );
  test('admissible storm and orbit keep the saved vertical wave spectrum', () {
    for (final scene in scenes.where(
      (s) => s.id == 'storm' || s.id == 'orbit',
    )) {
      final state = scene.sea;
      final original = OceanSeaState(
        seed: state.seed,
        canonicalResolution: state.canonicalResolution,
        bands: [
          for (final band in state.bands)
            OceanWaveBand.fromJson({
              ...band.toJson(),
              'choppiness': scene.id == 'storm' ? .7 : .5,
            }),
        ],
      );
      final currentSpectrum = OceanSpectrum(state),
          originalSpectrum = OceanSpectrum(original);
      for (final seconds in [0.0, 1.0, 10.0, 30.0]) {
        expect(
          currentSpectrum.evolveDifferential(0, seconds).height,
          originalSpectrum.evolveDifferential(0, seconds).height,
        );
      }
    }
  });
  for (final scene in scenes) {
    test(
      '${scene.id} admits physical samples across the saved route duration',
      () async {
        final frame = GeoWorldFrame(
          reference: const GeospatialReference(),
          origin: Geodetic(0, 0),
        );
        var now = GeoInstant(tick: 0, hz: 60, epoch: scene.epoch);
        final sampler = await OceanSamplerCpu.create(
          state: scene.sea,
          frame: frame,
          now: () => now,
          coverage: const OceanAllWaterCoverage(),
        );
        final policy = OceanQueryPolicy();
        try {
          for (final seconds in [0, 1, 10, 30]) {
            now = GeoInstant(tick: seconds * 60, hz: 60, epoch: scene.epoch);
            final results = await sampler.sampleBatch([
              for (final offset in [
                Vec3.zero,
                const Vec3(10, 0, 0),
                const Vec3(-10, 10, 0),
              ])
                OceanQuery(frame.toEcef(offset), now),
            ], policy);
            for (final result in results) {
              expect(
                result.failure,
                isNull,
                reason: '${scene.id} at $seconds seconds',
              );
              expect(
                result.accuracy!.heightErrorMetres,
                lessThanOrEqualTo(policy.maxHeightErrorMetres),
              );
              expect(
                result.accuracy!.normalErrorRadians,
                lessThanOrEqualTo(policy.maxNormalErrorRadians),
              );
              expect(
                result.accuracy!.velocityErrorMetresPerSecond,
                lessThanOrEqualTo(policy.maxVelocityErrorMetresPerSecond),
              );
              expect(result.age, Duration.zero);
            }
          }
        } finally {
          await sampler.close();
          await frame.dispose();
        }
      },
    );
  }
}
