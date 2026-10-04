import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:planet/ocean/scenes/coast_store.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:planet/ocean/scenes/world.dart';

void main() {
  test(
    'daylight storm has no black atmospheric-ground reflection streaks',
    () async {
      final directory = await Directory.systemTemp.createTemp('ocean-horizon-');
      final coast = await OceanLabCoast.open(
        directory,
        allowFixtureGeneration: true,
      );
      final backend = await NativeBackend.create();
      await backend.configureResourceBudget(768 * 1024 * 1024);
      final definition = OceanLabSceneDefinition.decode(
        File('assets/ocean/scenes.json').readAsStringSync(),
      ).firstWhere((s) => s.id == 'storm');
      final lab = OceanLabWorld(
        definition,
        coast,
        detail: OceanLabDetail.detailed,
      );
      final engine = await SceneEngine.create(
        scene: lab.scene,
        camera: lab.camera,
        backendFactory: () async => backend.createView(),
        plugins: lab.plugins,
      );
      try {
        await engine.render(elapsed: Duration.zero, width: 640, height: 400);
        final frame = await engine.render(
          elapsed: const Duration(microseconds: 16667),
          width: 640,
          height: 400,
        );
        var dark = 0;
        // Fixed daylight fixture, below the horizon and above the near foreground.
        // A geometry hole or a black LUT reflection is a defect in this region.
        for (var y = 150; y < 300; y++) {
          for (var x = 0; x < 640; x++) {
            final offset = (y * 640 + x) * 4;
            if (frame.pixels[offset] < 20 &&
                frame.pixels[offset + 1] < 20 &&
              frame.pixels[offset + 2] < 20) {
            dark++;
          }
          }
        }
        expect(dark, lessThan(10));
        expect(lab.simulationFailure, isNull);
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).liveAllocations, 0);
        await backend.close();
        await coast.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
