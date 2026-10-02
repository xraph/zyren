import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test('CIE lookup preserves source endpoints and interpolation', () {
    expect(Cie1931.matching(360), Vec3.zero);
    expect(Cie1931.matching(830), Vec3.zero);
    expect(Cie1931.matching(555), Vec3(.5120501, 1, .005749999));
    expect(
      Cie1931.matching(
        552.5,
      ).distanceTo((Cie1931.matching(550) + Cie1931.matching(555)) * .5),
      lessThan(1e-14),
    );
    expect(() => Cie1931.matching(double.nan), throwsArgumentError);
  });
  test(
    'spectra own samples, validate their domain and preserve out-of-gamut RGB',
    () {
      final wavelengths = [360.0, 830.0], values = [1.0, 1.0];
      final spectrum = SpectralDistribution(
        wavelengths: wavelengths,
        values: values,
      );
      values[0] = 0;
      wavelengths[0] = 400;
      expect(spectrum.sample(400), 1);
      expect(() => spectrum.values[0] = 2, throwsUnsupportedError);
      expect(spectrum.sample(359), 0);
      expect(spectrum.sample(831), 0);
      final blue = SpectralDistribution(
        wavelengths: [430, 435, 440],
        values: [0, 1, 0],
      ).toLinearSrgb();
      expect(blue.z, greaterThan(blue.x));
      expect(blue.y, lessThan(0));
      for (final bad in [
        [360.0, 360.0],
        [830.0, 360.0],
        [double.nan, 600.0],
      ]) {
        expect(
          () => SpectralDistribution(wavelengths: bad, values: [1, 1]),
          throwsArgumentError,
        );
      }
      expect(
        () => SpectralDistribution(wavelengths: [360, 830], values: [1, -1]),
        throwsArgumentError,
      );
      expect(
        () => SpectralDistribution(
          wavelengths: [360, 830],
          values: [1, double.infinity],
        ),
        throwsArgumentError,
      );
      expect(
        () => SpectralDistribution(wavelengths: [360], values: [1]),
        throwsArgumentError,
      );
    },
  );
  test(
    'spectral integration matches independent quadrature of the original CIE helper',
    () {
      final reference =
          jsonDecode(
                File(
                  'test/fixtures/atmosphere/spectra.json',
                ).readAsStringSync(),
              )
              as Map;
      for (final row in reference['lookup']) {
        final expected = Vec3.array(
          (row['xyz'] as List).cast<num>().map((n) => n.toDouble()).toList(),
        );
        expect(
          Cie1931.matching((row['nm'] as num).toDouble()).distanceTo(expected),
          lessThan(1e-14),
        );
      }
      for (final row in reference['spectra']) {
        final spectrum = SpectralDistribution(
          wavelengths: (row['wavelengths'] as List).cast<num>().map(
            (n) => n.toDouble(),
          ),
          values: (row['values'] as List).cast<num>().map((n) => n.toDouble()),
        );
        for (final (value, key) in [
          (spectrum.toXyz(), 'xyz'),
          (spectrum.toLinearSrgb(), 'rgb'),
        ]) {
          final expected = Vec3.array(
            (row[key] as List).cast<num>().map((n) => n.toDouble()).toList(),
          );
          expect(
            value.distanceTo(expected),
            lessThan(.001),
            reason: row['name'],
          );
        }
      }
    },
  );
}
