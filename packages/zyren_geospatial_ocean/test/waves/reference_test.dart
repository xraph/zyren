import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test('a DC coefficient normalizes to a uniform real field', () {
    final values = Float64List(2 * 4 * 4)..[0] = 16;
    final field = inverseDft2(values, 4);
    for (var i = 0; i < 16; i++) {
      expect(field[2 * i], closeTo(1, 1e-12));
      expect(field[2 * i + 1], closeTo(0, 1e-12));
    }
  });
  test(
    'all-frequency impulse, conjugate pair and complex sign use one normalization',
    () {
      final values = Float64List(32);
      for (var i = 0; i < 16; i++) {
        values[i * 2] = 1;
      }
      final impulse = inverseDft2(values, 4);
      expect(impulse[0], closeTo(1, 1e-12));
      for (final v in impulse.skip(1)) {
        expect(v, closeTo(0, 1e-12));
      }
      values.fillRange(0, values.length, 0);
      values[2] = 8;
      values[6] = 8;
      final cosine = inverseDft2(values, 4);
      for (var z = 0; z < 4; z++) {
        for (var x = 0; x < 4; x++) {
          expect(
            cosine[2 * (z * 4 + x)],
            closeTo(math.cos(math.pi * x / 2), 1e-12),
          );
        }
      }
      values.fillRange(0, values.length, 0);
      values[3] = 16;
      final imaginary = inverseDft2(values, 4);
      expect(imaginary[2], closeTo(-1, 1e-12));
      expect(imaginary[3], closeTo(0, 1e-12));
      expect(inverseDft2(Float64List(32), 4), everyElement(0));
    },
  );
  test('reference work and invalid input are bounded', () {
    expect(() => inverseDft2(Float64List(0), 4), throwsArgumentError);
    expect(
      () => inverseDft2(Float64List(2 * 64 * 64), 64),
      throwsArgumentError,
    );
    expect(
      () => inverseDft2(Float64List(32)..[1] = double.nan, 4),
      throwsArgumentError,
    );
  });
}
