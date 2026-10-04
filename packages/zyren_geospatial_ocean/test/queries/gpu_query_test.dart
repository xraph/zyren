import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native canonical batches agree with Float64 fields and cover observed error',
    () async {
      final backend = await NativeBackend.create(),
          scope = GpuScope.fromBackend(backend);
      final gpu = await OceanCanonicalGpu.create(
        scope,
        maxSamples: 8,
        maxModes: 4096,
      );
      try {
        for (final state in [
          for (final size in [8, 32, 64]) fixtureSea(resolution: size),
          OceanSeaState(
            seed: 21,
            canonicalResolution: 32,
            bands: [
              ...fixtureSea().bands,
              OceanWaveBand(
                patchMetres: 48,
                minWaveNumber: .1,
                maxWaveNumber: 5,
                windSpeed: 9,
                windHeadingRadians: -.2,
                amplitude: .001,
              ),
            ],
          ),
        ]) {
          final field = OceanCanonicalField(state, maxModes: 4096);
          for (final time in [1.3, 1e10 + .25]) {
            final snapshot = field.at(time),
                points = [
                  (0.0, 0.0),
                  (6378137.13, -2341312.22),
                  (-31.99, 32.01),
                ];
            final batch = await gpu.sample(snapshot, points);
            expect(batch.seconds, time);
            expect(batch.seaStateRevision, snapshot.seaStateRevision);
            expect(batch.dispatches, 1);
            for (var i = 0; i < points.length; i++) {
              final (x, z) = points[i];
              final expected = snapshot.sample(x, z),
                  actual = batch.values[i],
                  error = batch.errors[i];
              expect(actual.height, closeTo(expected.height, 1e-4));
              expect(
                (actual.height - expected.height).abs(),
                lessThanOrEqualTo(error.height),
              );
              expect(
                (actual.displacementX - expected.displacementX).abs(),
                lessThanOrEqualTo(error.displacement),
              );
              expect(
                (actual.displacementZ - expected.displacementZ).abs(),
                lessThanOrEqualTo(error.displacement),
              );
              expect(
                (actual.slopeX - expected.slopeX).abs(),
                lessThanOrEqualTo(error.slope),
              );
              expect(
                (actual.velocityY - expected.velocityY).abs(),
                lessThanOrEqualTo(error.velocity),
              );
              expect(
                (actual.displacementXX - expected.displacementXX).abs(),
                lessThanOrEqualTo(error.displacementGradient),
              );
              expect(
                actual.displacementX,
                closeTo(expected.displacementX, 1e-4),
              );
              expect(
                actual.displacementZ,
                closeTo(expected.displacementZ, 1e-4),
              );
              expect(actual.slopeX, closeTo(expected.slopeX, 1e-4));
              expect(actual.slopeZ, closeTo(expected.slopeZ, 1e-4));
              expect(actual.velocityX, closeTo(expected.velocityX, 1e-4));
              expect(actual.velocityY, closeTo(expected.velocityY, 1e-4));
              expect(actual.velocityZ, closeTo(expected.velocityZ, 1e-4));
              expect(
                actual.displacementXX,
                closeTo(expected.displacementXX, 1e-4),
              );
              expect(
                actual.displacementXZ,
                closeTo(expected.displacementXZ, 1e-4),
              );
              expect(
                actual.displacementZX,
                closeTo(expected.displacementZX, 1e-4),
              );
              expect(
                actual.displacementZZ,
                closeTo(expected.displacementZZ, 1e-4),
              );
            }
          }
        }
        final flatState = OceanSeaState(
          seed: 42,
          canonicalResolution: 8,
          bands: fixtureSea(wind: 0).bands,
          meanLevel: 1234.56789,
        );
        final flat = await gpu.sample(
          OceanCanonicalField(flatState, maxModes: 64).at(0),
          [(1e12, -1e12)],
        );
        expect(flat.values.single.height, flatState.meanLevel);
        expect(flat.values.single.displacementX, 0);
        expect(flat.values.single.velocityY, 0);
        expect(flat.errors.single.height, 0);
        expect(() => flat.values.clear(), throwsUnsupportedError);
      } finally {
        await gpu.close();
        expect(scope.childCount, 0);
        await scope.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
