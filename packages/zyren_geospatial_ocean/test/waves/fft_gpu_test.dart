import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import '../support/sea_states.dart';

void main() {
  test('native Stockham inverse matches the independent complex DFT', () async {
    final backend = await NativeBackend.create();
    final scope = GpuScope.fromBackend(backend);
    final field = await OceanWaveFieldGpu.create(scope, fixtureSea());
    try {
      for (final size in [4, 8]) {
        final coefficients = Float64List(2 * size * size);
        for (var i = 0; i < coefficients.length; i++) {
          coefficients[i] = ((i * 13 + 7) % 31 - 15) / 7;
        }
        final expected = inverseDft2(coefficients, size);
        final actual = await field.debugInverse(coefficients, size: size);
        for (var i = 0; i < expected.length; i++) {
          expect(
            actual[i],
            closeTo(expected[i], 2e-5),
            reason: 'N=$size scalar=$i',
          );
        }
      }
    } finally {
      await field.close();
      expect(scope.childCount, 0);
      await scope.close();
      expect((await backend.resourceStats()).liveAllocations, 0);
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
