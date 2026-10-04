import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'sample_test.dart' show queryFrame, queryTime, querySea;

void main() {
  test(
    'native world batches meet policy and survive actual display-grid changes',
    () async {
      final backend = await NativeBackend.create(),
          scope = GpuScope.fromBackend(backend),
          frame = queryFrame(),
          state = querySea(),
          time = queryTime();
      final cpu = await OceanSamplerCpu.create(
        state: state,
        frame: frame,
        now: () => time,
        coverage: const OceanAllWaterCoverage(),
      );
      final gpu = await OceanSamplerGpu.create(
        state: state,
        frame: frame,
        now: () => time,
        coverage: const OceanAllWaterCoverage(),
        scope: scope,
      );
      final visual = await OceanWaveFieldGpu.create(scope, state);
      final random = math.Random(814);
      final queries = [
        for (var i = 0; i < 24; i++)
          OceanQuery(
            Ellipsoid.wgs84.toEcef(
              Geodetic(
                random.nextDouble() * 2 * math.pi - math.pi,
                (random.nextDouble() - .5) * math.pi,
              ),
            ),
            time,
          ),
      ];
      final policy = OceanQueryPolicy();
      try {
        final before = await cpu.sampleBatch(queries, policy);
        final native = await gpu.sampleBatch(queries, policy);
        var height = 0.0, angle = 0.0, velocity = 0.0;
        for (var i = 0; i < queries.length; i++) {
          final a = before[i], b = native[i];
          expect(a.failure, isNull, reason: 'CPU $i');
          expect(b.failure, isNull, reason: 'GPU $i');
          final dh = (a.height! - b.height!).abs(),
              dn = math.atan2(
                a.value!.normalEcef.cross(b.value!.normalEcef).length,
                a.value!.normalEcef.dot(b.value!.normalEcef),
              ),
              dv = (a.value!.velocityEcef - b.value!.velocityEcef).length;
          height = math.max(height, dh);
          angle = math.max(angle, dn);
          velocity = math.max(velocity, dv);
          expect(
            dh,
            lessThan(
              a.accuracy!.heightErrorMetres + b.accuracy!.heightErrorMetres,
            ),
          );
          expect(
            dn,
            lessThan(
              a.accuracy!.normalErrorRadians + b.accuracy!.normalErrorRadians,
            ),
          );
          expect(
            dv,
            lessThan(
              a.accuracy!.velocityErrorMetresPerSecond +
                  b.accuracy!.velocityErrorMetresPerSecond,
            ),
          );
          expect(dh, lessThan(.01));
          expect(dn, lessThan(math.pi / 360));
        }
        expect(gpu.diagnostics.gpuDispatches, lessThan(24 * 3));
        final dispatches = gpu.diagnostics.gpuDispatches;
        final high = await visual.evaluate(time.seconds, resolution: 8);
        final highBytes = high.logicalPayloadBytes;
        final low = await visual.evaluate(time.seconds, resolution: 4);
        expect(low.logicalPayloadBytes, lessThan(highBytes));
        final after = await cpu.sampleBatch(queries, policy),
            afterGpu = await gpu.sampleBatch(queries, policy);
        expect(after.every((s) => s.available), isTrue);
        expect(afterGpu.every((s) => s.available), isTrue);
        expect(after.map((s) => s.height), before.map((s) => s.height));
        expect(afterGpu.map((s) => s.height), native.map((s) => s.height));
        expect(
          after.every((s) => s.seaStateRevision == state.revision),
          isTrue,
        );
        print(
          jsonEncode({
            'samples': queries.length,
            'maxHeightDifferenceMetres': height,
            'maxNormalDifferenceRadians': angle,
            'maxVelocityDifferenceMetresPerSecond': velocity,
            'gpuDispatches': dispatches,
            'visualGrid8Bytes': highBytes,
            'visualGrid4Bytes': low.logicalPayloadBytes,
          }),
        );
      } finally {
        await visual.close();
        await cpu.close();
        await gpu.close();
        await scope.close();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
        await frame.dispose();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
