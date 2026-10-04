import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'visual band limits change native work without reseeding retained modes',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final state = OceanSeaState(
        seed: 42,
        canonicalResolution: 16,
        bands: [
          OceanWaveBand(
            patchMetres: 64,
            minWaveNumber: 0,
            maxWaveNumber: .7,
            windSpeed: 12,
            windHeadingRadians: .3,
            amplitude: .02,
          ),
          OceanWaveBand(
            patchMetres: 32,
            minWaveNumber: .1,
            maxWaveNumber: 2,
            windSpeed: 8,
            windHeadingRadians: .8,
            amplitude: .02,
          ),
        ],
      );
      final field = await OceanWaveFieldGpu.create(
        owner,
        oceanChartSeaState(state, 0),
      );
      try {
        final full = await field.evaluate(2, resolution: 16);
        final first = await field.debugRead(full);
        final packedFull = await OceanWaveRenderData.pack(
          owner,
          state: state,
          charts: {0: full},
        );
        final limited = await field.evaluate(2, resolution: 16, bandCount: 1);
        expect(limited.seaStateRevision, full.seaStateRevision);
        expect(limited.bands, hasLength(1));
        expect(limited.dispatches * 2, full.dispatches);
        expect(limited.logicalPayloadBytes * 2, full.logicalPayloadBytes);
        expect(limited.omittedBandSlopeVariance, greaterThan(0));
        expect(
          (await field.debugRead(limited)).displacement,
          first.displacement,
        );
        final packed = await OceanWaveRenderData.pack(
          owner,
          state: state,
          charts: {0: limited},
        );
        expect(packed.bandCount, 1);
        expect(packed.logicalPayloadBytes * 2, packedFull.logicalPayloadBytes);
        expect(await packed.debugRead(0), await packedFull.debugRead(0));
        expect(
          packed.unresolvedSlopeVariance[0]!.first,
          limited.omittedBandSlopeVariance,
        );
        await expectLater(
          field.evaluate(3, resolution: 16, bandCount: 0),
          throwsArgumentError,
        );
        expect(limited.isCurrent, isTrue);
        await expectLater(packed.debugRead(0, band: 1), throwsRangeError);
        final restored = await field.evaluate(2, resolution: 16, bandCount: 2);
        expect(
          (await field.debugRead(restored)).displacement,
          first.displacement,
        );
        expect(restored.omittedBandSlopeVariance, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
