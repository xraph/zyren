import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native visual mips preserve means, variance and immutable times',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea(), chartState = oceanChartSeaState(state, 0);
      final field = await OceanWaveFieldGpu.create(scope, chartState);
      try {
        final source = await field.evaluate(2.0, resolution: 8);
        final sourceData = await field.debugRead(source);
        final packed = await OceanWaveRenderData.pack(
          scope,
          state: state,
          charts: {0: source},
        );
        expect(packed.resolution, 8);
        expect(packed.levels, 4);
        expect(packed.logicalPayloadBytes, 8 * 8 * 64);
        final full = await packed.debugRead(0);
        for (var i = 0; i < 64; i++) {
          for (var c = 0; c < 4; c++) {
            expect(full[i * 12 + c], sourceData.displacement[i * 4 + c]);
            expect(full[i * 12 + 4 + c], sourceData.derivatives[i * 4 + c]);
          }
          expect(full[i * 12 + 8], sourceData.velocity[i * 4 + 3]);
        }
        for (var level = 1; level < 4; level++) {
          final mip = await packed.debugRead(0, level: level);
          final width = 8 >> level, stride = 1 << level;
          for (var y = 0; y < width; y++) {
            for (var x = 0; x < width; x++) {
              for (var c = 0; c < 12; c++) {
                var sum = 0.0;
                for (var dy = 0; dy < stride; dy++) {
                  for (var dx = 0; dx < stride; dx++) {
                    sum +=
                        full[((y * stride + dy) * 8 + x * stride + dx) * 12 +
                            c];
                  }
                }
                expect(
                  mip[(y * width + x) * 12 + c],
                  closeTo(sum / (stride * stride), 2e-6),
                );
              }
            }
          }
        }
        final mean = await packed.debugRead(0, level: 3);
        expect(mean[1], closeTo(0, 1e-6));
        expect(mean[9], greaterThan(0));
        await field.evaluate(4, resolution: 4);
        expect(source.isCurrent, isFalse);
        expect(await packed.debugRead(0), full);
        await expectLater(
          OceanWaveRenderData.pack(scope, state: state, charts: {0: source}),
          throwsStateError,
        );
        await packed.close();
      } finally {
        await scope.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'render packing rejects mismatched chart identity and byte budgets',
    () async {
      final backend = await NativeBackend.create();
      final scope = GpuScope.fromBackend(backend);
      final state = fixtureSea();
      final field = await OceanWaveFieldGpu.create(
        scope,
        oceanChartSeaState(state, 2),
      );
      try {
        final source = await field.evaluate(0, resolution: 8);
        final before = (await backend.resourceStats()).residentBytes;
        await expectLater(
          OceanWaveRenderData.pack(scope, state: state, charts: {1: source}),
          throwsArgumentError,
        );
        await expectLater(
          OceanWaveRenderData.pack(
            scope,
            state: state,
            charts: {2: source},
            maxLogicalBytes: 100,
          ),
          throwsA(isA<ResourceException>()),
        );
        expect((await backend.resourceStats()).residentBytes, before);
      } finally {
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
