import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'celestial vectors and rotations match pinned Astronomy Engine 2.1.19',
    () {
      final fixture =
          jsonDecode(
                File(
                  'test/fixtures/atmosphere/celestial.json',
                ).readAsStringSync(),
              )
              as Map;
      var maximumDirectionError = 0.0, maximumRotationError = 0.0;
      for (final c in fixture['timeCases'] as List) {
        final time = AstronomicalTime(DateTime.parse(c['date'] as String));
        expect(time.utDays, closeTo(c['ut'] as num, 1e-10));
        expect(time.ttDays, closeTo(c['tt'] as num, 1e-10));
        expect(time.deltaTSeconds, closeTo(c['deltaT'] as num, 1e-9));
      }
      for (final c in fixture['cases'] as List) {
        final observer = c['observer'] as List?;
        final value = CelestialDirections.at(
          DateTime.parse(c['date'] as String),
          observerECEF: observer == null
              ? null
              : Vec3(
                  (observer[0] as num).toDouble(),
                  (observer[1] as num).toDouble(),
                  (observer[2] as num).toDouble(),
                ),
        );
        expect(value.time.utDays, closeTo(c['ut'] as num, 1e-10));
        expect(value.time.ttDays, closeTo(c['tt'] as num, 1e-10));
        expect(value.siderealHours, closeTo(c['siderealHours'] as num, 1e-9));
        for (final (actual, key) in [
          (value.sunECI, 'sunECI'),
          (value.moonECI, 'moonECI'),
          (value.sunECEF, 'sunECEF'),
          (value.moonECEF, 'moonECEF'),
        ]) {
          final expected = c[key] as List;
          for (final (i, v) in [actual.x, actual.y, actual.z].indexed) {
            final error = (v - (expected[i] as num)).abs();
            if (error > maximumDirectionError) maximumDirectionError = error;
            expect(
              v,
              closeTo(expected[i] as num, 2e-10),
              reason: '${c['date']} $key/$i',
            );
          }
          expect(actual.length, closeTo(1, 1e-12));
        }
        for (final (actual, key) in [
          (value.eciToEcef, 'eciToEcef'),
          (value.moonFixedToEci, 'moonFixedToEci'),
        ]) {
          final expected = c[key] as List;
          for (var i = 0; i < 16; i++) {
            final error = (actual.storage[i] - (expected[i] as num)).abs();
            if (error > maximumRotationError) maximumRotationError = error;
            expect(
              actual.storage[i],
              closeTo(expected[i] as num, 2e-10),
              reason: '${c['date']} $key/$i',
            );
          }
        }
        expect(
          value.sunDistanceMeters,
          closeTo(c['sunDistanceMeters'] as num, .1),
        );
        expect(
          value.moonDistanceMeters,
          closeTo(c['moonDistanceMeters'] as num, .001),
        );
      }
      print(
        'Celestial errors: direction=$maximumDirectionError matrix=$maximumRotationError',
      );
    },
  );
  test(
    'UTC offsets identify the same instant and independent calls stay stable',
    () {
      final first = CelestialDirections.at(
        DateTime.parse('2026-09-28T00:00:00Z'),
      );
      CelestialDirections.at(DateTime.utc(1900));
      final offset = CelestialDirections.at(
        DateTime.parse('2026-09-27T19:00:00-05:00'),
      );
      expect(first.sunECEF, offset.sunECEF);
      expect(first.moonECEF, offset.moonECEF);
      expect(
        () => CelestialDirections.at(DateTime.utc(10001)),
        throwsArgumentError,
      );
      expect(
        () => CelestialDirections.at(
          DateTime.utc(2026),
          observerECEF: const Vec3(double.nan, 0, 0),
        ),
        throwsArgumentError,
      );
    },
  );
}
