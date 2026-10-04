import 'dart:io';
import 'package:test/test.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:planet/ocean/scenes/coast_store.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'saved scenes have reproducible state and effective custom work limits',
    () {
      final scenes = OceanLabSceneDefinition.decode(
        File('assets/ocean/scenes.json').readAsStringSync(),
      );
      expect(scenes.map((s) => s.id), [
        'calm',
        'storm',
        'coast',
        'vessel',
        'underwater',
        'orbit',
      ]);
      for (final scene in scenes) {
        expect(scene.sea.revision, scene.sea.revision);
        for (final detail in OceanLabDetail.values) {
          expect(
            detail.settings.fftResolution,
            lessThanOrEqualTo(scene.sea.canonicalResolution),
          );
          expect(detail.settings.preset, isNull);
        }
      }
    },
  );
  test(
    'coast cold restart reads verified region bytes without invoking transport',
    () async {
      final directory = await Directory.systemTemp.createTemp('ocean-offline-');
      final time = GeoInstant(tick: 0, hz: 60, epoch: DateTime.utc(2026));
      try {
        final generated = await OceanLabCoast.open(
          directory,
          allowFixtureGeneration: true,
        );
        final original = await generated.read('depth');
        expect(generated.fetches, 3);
        await generated.close();
        final offline = await OceanLabCoast.open(directory);
        expect((await offline.read('depth')).values, original.values);
        expect(
          (await offline.coverage.sample(Geodetic(0, 0), time)).value,
          isTrue,
        );
        expect(
          (await offline.coverage.sample(Geodetic(.000019, 0), time)).value,
          isFalse,
        );
        expect(
          (await offline.coverage.sample(Geodetic(.1, 0), time)).availability,
          GeoSampleAvailability.outsideCoverage,
        );
        expect(offline.fetches, 0);
        expect(offline.job.plan!.region.sourceVersions, {
          'ocean-lab-coast': OceanLabCoast.revision,
        });
        await offline.close();
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}
