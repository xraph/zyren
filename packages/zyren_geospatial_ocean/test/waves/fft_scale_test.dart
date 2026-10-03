import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test(
    'native grids from 64 through 512 stay within declared payload and release',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final scope = GpuScope.fromBackend(backend);
      addTearDown(scope.close);
      final field = await OceanWaveFieldGpu.create(
        scope,
        fixtureSea(resolution: 512),
      );
      addTearDown(field.close);
      final physical = OceanSpectrum(fixtureSea(resolution: 64));
      for (final size in [64, 128, 256, 512]) {
        final watch = Stopwatch()..start();
        final snapshot = await field.evaluate(2.3, resolution: size);
        final elapsed = watch.elapsedMilliseconds;
        final read = await field.debugRead(snapshot);
        expect(read.displacement.every((v) => v.isFinite), isTrue);
        expect(read.derivatives.every((v) => v.isFinite), isTrue);
        expect(read.velocity.every((v) => v.isFinite), isTrue);
        expect(
          snapshot.logicalPayloadBytes,
          (await backend.resourceStats()).residentBytes,
        );
        final expected = physical.reference(16, 32, 2.3);
        final i = 4 * ((size ~/ 2) * size + size ~/ 4);
        expect(read.displacement[i + 1], closeTo(expected.height, 3e-5));
        print(
          'Ocean N=$size bands=1 logicalBytes=${snapshot.logicalPayloadBytes} coldEvaluateMs=$elapsed',
        );
      }
      await field.close();
      expect((await backend.resourceStats()).liveAllocations, 0);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
