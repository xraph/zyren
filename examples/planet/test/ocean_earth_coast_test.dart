import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_capture/zyren_capture.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:planet/ocean/scenes/earth_coast.dart';
import 'package:planet/ocean/scenes/world.dart';

void main() {
  Future<OceanEarthCoast> open(Directory directory, {bool import = false}) =>
      OceanEarthCoast.open(
        directory,
        manifest: File(
          '${OceanEarthCoast.assetDirectory}/manifest.json',
        ).readAsStringSync(),
        loadBundle: import
            ? (name) => File(
                '${OceanEarthCoast.assetDirectory}/$name.zgrid',
              ).readAsBytes()
            : null,
      );

  test(
    'NOAA coast persists its datum and reopens without asset or network reads',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'monterey-offline-',
      );
      try {
      await expectLater(open(directory), throwsA(isA<GeoDataException>()));
        final imported = await open(directory, import: true);
        expect(imported.fetches, 4);
        final height = await imported.read('height');
        final geoid = await imported.read('geoid');
        final depth = await imported.read('depth');
        final water = await imported.read('water');
        var wet = 0, dry = 0;
        for (var i = 0; i < height.values.length; i++) {
          final orthometric = height.values[i] - geoid.values[i];
          if (water.values[i] == 1) {
            wet++;
            expect(depth.values[i], closeTo(-orthometric, 1e-8));
          } else {
            dry++;
            expect(depth.values[i], 0);
            expect(orthometric, greaterThanOrEqualTo(0));
          }
        }
        expect(wet, greaterThan(100));
        expect(dry, greaterThan(100));
        await imported.close();
        final offline = await open(directory);
        try {
          final time = GeoInstant(tick: 0, hz: 60, epoch: DateTime.utc(2026));
          expect((await offline.read('height')).values, height.values);
          expect(
            (await offline.coverage.sample(offline.origin, time)).value,
            isTrue,
          );
          expect(
            (await offline.coverage.sample(
              Geodetic.degrees(-121.85, 36.59),
              time,
            )).value,
            isFalse,
          );
          expect(
            (await offline.coverage.sample(Geodetic(0, 0), time)).availability,
            GeoSampleAvailability.outsideCoverage,
          );
          expect(offline.job.plan!.digest, offline.plan.digest);
          expect(offline.fetches, 0);
        } finally {
          await offline.close();
        }
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'import rejects altered bundled grids before region publication',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'monterey-corrupt-',
      );
      try {
        await expectLater(
          OceanEarthCoast.open(
            directory,
            manifest: File(
              '${OceanEarthCoast.assetDirectory}/manifest.json',
            ).readAsStringSync(),
            loadBundle: (name) async {
              final bytes = await File(
                '${OceanEarthCoast.assetDirectory}/$name.zgrid',
              ).readAsBytes();
              bytes[100] ^= 1;
              return bytes;
            },
          ),
        throwsA(isA<GeoDataException>()),
        );
      await expectLater(open(directory), throwsA(isA<GeoDataException>()));
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );

  test(
    'cold NOAA region renders native coastline and accepts physical water samples',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'monterey-native-',
      );
      final imported = await open(directory, import: true);
      await imported.close();
      final coast = await open(directory);
      final backend = await NativeBackend.create();
      await backend.configureResourceBudget(768 * 1024 * 1024);
      final lab = OceanLabWorld(
        OceanLabSceneDefinition.monterey(coast.seaLevel),
        coast,
      );
      final engine = await SceneEngine.create(
        scene: lab.scene,
        camera: lab.camera,
        backendFactory: () async => backend.createView(),
        plugins: lab.plugins,
      );
      try {
        final frame = await engine.render(
          elapsed: Duration.zero,
          width: 960,
          height: 600,
        );
        await engine.render(
          elapsed: const Duration(milliseconds: 17),
          width: 960,
          height: 600,
        );
        final sampler = lab.host.registry.find(oceanSampler)!;
        final samples = await sampler.sampleBatch([
          OceanQuery(
            lab.host.worldFrame.toEcef(Vec3.zero),
            lab.host.clock.instant,
          ),
          OceanQuery(
            Ellipsoid.wgs84.toEcef(Geodetic.degrees(-121.85, 36.59)),
            lab.host.clock.instant,
          ),
        ], OceanQueryPolicy());
        expect(samples[0].available, isTrue, reason: '${samples[0].failure}');
        expect(samples[1].available, isFalse);
        expect(samples[1].failure, OceanQueryFailure.outsideCoverage);
        expect(coast.fetches, 0);
        expect(lab.simulationFailure, isNull);
        final capture = Platform.environment['OCEAN_EARTH_CAPTURE'];
        if (capture != null) {
          await File(capture).writeAsBytes(
            encodeCapturePng(
              ImageData(pixels: frame.pixels, size: PhysicalSize(960, 600)),
            ),
          );
        }
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).liveAllocations, 0);
        expect((await backend.graphStats()).liveGraphs, 0);
        await backend.close();
        await coast.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
