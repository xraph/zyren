import 'dart:math' as math;
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'balanced LUT layout stays within the measured source-grid error budget',
    () {
      Map fixture(String name) =>
          jsonDecode(
                File(
                  'test/fixtures/atmosphere/scattering-$name.json',
                ).readAsStringSync(),
              )
              as Map;
      final balanced = fixture('balanced')['radiance'] as List;
      final reference = fixture('reference')['radiance'] as List;
      expect(balanced.length, 648);
      expect(reference.length, 648);
      final errors = <double>[];
      var maxAbsolute = 0.0;
      for (var i = 0; i < reference.length; i++) {
        expect(balanced[i]['coordinates'], reference[i]['coordinates']);
        var peak = .001, error = 0.0;
        for (var c = 0; c < 3; c++) {
          final expected = (reference[i]['rgb'][c] as num).toDouble();
          peak = math.max(peak, expected);
          error = math.max(
            error,
            ((balanced[i]['rgb'][c] as num) - expected).abs(),
          );
        }
        errors.add(error / peak);
        maxAbsolute = math.max(maxAbsolute, error);
      }
      errors.sort();
      expect(errors[(errors.length * .95).floor()], lessThan(.035));
      expect(errors.last, lessThan(.55));
      expect(maxAbsolute, lessThan(.01));
      expect(AtmosphereQuality.balanced.residentBytes, 14434304);
    },
  );
  test(
    'atmosphere parameters keep metre units and source defaults distinct',
    () {
      final a = AtmosphereParameters.legacy();
      final b = AtmosphereParameters.webgpu();
      expect(a.bottomRadius, 6360000);
      expect(a.topRadius, 6420000);
      expect(a.rayleighScattering.z, .0000331);
      expect(a.groundAlbedo.x, .1);
      expect(b.groundAlbedo.x, .3);
      expect(a.mieDensity.density(1200), closeTo(math.exp(-.9999996), 1e-12));
      expect(b.mieDensity.density(1200), closeTo(math.exp(-1), 1e-12));
      for (final profile in [
        a.rayleighDensity,
        a.mieDensity,
        a.absorptionDensity,
      ]) {
        for (var h = 0.0; h <= 60000; h += 100) {
          expect(profile.density(h), inInclusiveRange(0, 1));
        }
      }
      expect(a.absorptionDensity.density(10000), closeTo(0, 1e-12));
      expect(a.absorptionDensity.density(25000), closeTo(1, 1e-12));
      expect(a.absorptionDensity.density(40000), closeTo(0, 1e-12));
      expect(a.key, AtmosphereParameters.legacy().key);
      expect(a.key, isNot(b.key));
      expect(
        a.copyWith(groundAlbedo: const Vec3(.2, .2, .2)).key,
        isNot(a.key),
      );
      expect(() => a.copyWith(topRadius: a.bottomRadius), throwsArgumentError);
      expect(() => a.copyWith(miePhaseFunctionG: 1), throwsArgumentError);
      expect(
        () => a.copyWith(mieExtinction: const Vec3(0, 0, 0)),
        throwsArgumentError,
      );
      expect(() => a.copyWith(sunAngularRadius: 0), throwsArgumentError);
      expect(
        () => a.copyWith(rayleighScattering: const Vec3(-1, 0, 0)),
        throwsArgumentError,
      );
      expect(
        () => DensityLayer(expScale: double.infinity),
        throwsArgumentError,
      );
      expect(() => a.rayleighDensity.density(double.nan), throwsArgumentError);
    },
  );
}
