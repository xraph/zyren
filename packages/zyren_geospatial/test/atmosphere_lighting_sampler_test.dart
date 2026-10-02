import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'lighting owns its table data and separates irradiance from surface angle',
    () {
      final trans = Float32List(256 * 64 * 4)..fillRange(0, 256 * 64 * 4, 1);
      final irr = Float32List(64 * 16 * 4)..fillRange(0, 64 * 16 * 4, 2);
      final sampler = AtmosphereLightingSampler(
        parameters: AtmosphereParameters.legacy(),
        transmittance: trans,
        irradiance: irr,
      );
      trans.fillRange(0, trans.length, 0);
      irr.fillRange(0, irr.length, 0);
      final sun = Vec3(0, 0, 1);
      final sample = sampler.sample(
        positionECEF: Vec3(0, 0, 6360010),
        sunDirectionECEF: sun,
        correctAltitude: false,
      );
      final p = AtmosphereParameters.legacy();
      expect(
        sample.sunIrradiance.distanceTo(
          Vec3(
            p.solarIrradiance.x * p.sunRelativeLuminance.x,
            p.solarIrradiance.y * p.sunRelativeLuminance.y,
            p.solarIrradiance.z * p.sunRelativeLuminance.z,
          ),
        ),
        lessThan(1e-12),
      );
      expect(
        sample.skyIrradiance.distanceTo(p.skyRelativeLuminance * 2),
        lessThan(1e-12),
      );
      expect(sample.skyIrradianceAt(-sample.upECEF).length, closeTo(0, 1e-12));
      expect(
        sample.skyIrradianceAt(sample.upECEF).distanceTo(sample.skyIrradiance),
        lessThan(1e-12),
      );
      expect(
        sampler
            .sample(
              positionECEF: Vec3(0, 0, 6360010),
              sunDirectionECEF: -sun,
              correctAltitude: false,
            )
            .sunIrradiance
            .length,
        0,
      );
      expect(
        sampler
            .sample(
              positionECEF: Vec3(0, 0, 36000000),
              sunDirectionECEF: -sun,
              correctAltitude: false,
            )
            .sunIrradiance
            .length,
        0,
      );
      expect(
        () => sampler.sample(positionECEF: Vec3.zero, sunDirectionECEF: sun),
        throwsArgumentError,
      );
      expect(
        () => AtmosphereLightingSampler(
          parameters: p,
          transmittance: Float32List(1),
          irradiance: irr,
        ),
        throwsArgumentError,
      );
    },
  );
  final assets = Platform.environment['ZYREN_SOURCE_LUTS'];
  test(
    'sun light and probe agree with 48 upstream helper cases',
    () {
      Float32List load(String name, int width, int height) {
        final table = AtmosphereTableDecoder().decode(
          File('$assets/$name.bin').readAsBytesSync(),
          format: AtmosphereLutFormat.binary,
          width: width,
          height: height,
        );
        return Float32List.fromList([
          for (var y = 0; y < height; y++)
            for (var x = 0; x < width; x++)
              for (var c = 0; c < 4; c++) table.value(x, y, 0, c),
        ]);
      }

      final sampler = AtmosphereLightingSampler(
        parameters: AtmosphereParameters.legacy(),
        transmittance: load('transmittance', 256, 64),
        irradiance: load('irradiance', 64, 16),
      );
      final cases =
          jsonDecode(
                File(
                  'test/fixtures/atmosphere/lighting-source.json',
                ).readAsStringSync(),
              )['cases']
              as List;
      Vec3 vector(List list) => Vec3(
        (list[0] as num).toDouble(),
        (list[1] as num).toDouble(),
        (list[2] as num).toDouble(),
      );
      for (final row in cases) {
        final value = sampler.sample(
          positionECEF: vector(row['position']),
          sunDirectionECEF: vector(row['sun']),
          correctAltitude: row['correctAltitude'],
        );
        expect(
          value.sunIrradiance.distanceTo(vector(row['sunIrradiance'])),
          lessThan(1e-8),
          reason: 'sun ${row['position']} ${row['sun']}',
        );
        expect(
          value.skyIrradiance.distanceTo(vector(row['skyIrradiance'])),
          lessThan(1e-8),
        );
        final k = math.sqrt(3) / (2 * math.sqrt(math.pi));
        final coeffs = [
          value.skyIrradiance / math.sqrt(math.pi),
          value.skyIrradiance * (k * value.upECEF.y),
          value.skyIrradiance * (k * value.upECEF.z),
          value.skyIrradiance * (k * value.upECEF.x),
        ];
        for (var i = 0; i < 4; i++) {
          expect(
            coeffs[i].distanceTo(vector(row['coefficients'][i])),
            lessThan(1e-8),
          );
        }
      }
    },
    skip: assets == null
        ? 'Set ZYREN_SOURCE_LUTS for source lighting checks.'
        : false,
  );
}
