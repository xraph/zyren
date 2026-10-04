import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:planet/ocean/scenes/coast_store.dart';
import 'package:planet/ocean/scenes/world.dart';

void main() {
  test(
    'all saved scenes render native water with their declared effects and clean up',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'ocean-lab-native-',
      );
      final coast = await OceanLabCoast.open(
        directory,
        allowFixtureGeneration: true,
      );
      final scenes = OceanLabSceneDefinition.decode(
        File('assets/ocean/scenes.json').readAsStringSync(),
      );
      final backend = await NativeBackend.create();
      await backend.configureResourceBudget(768 * 1024 * 1024);
      try {
        for (final definition in scenes) {
          final lab = OceanLabWorld(
            definition,
            coast,
            detail: OceanLabDetail.preview,
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
              width: 160,
              height: 100,
            );
            final colors = <int>{};
            for (var i = 0; i < frame.pixels.length; i += 4) {
              colors.add(
                (frame.pixels[i] << 16) |
                    (frame.pixels[i + 1] << 8) |
                    frame.pixels[i + 2],
              );
            }
            expect(colors.length, greaterThan(8), reason: definition.id);
            await engine.render(
              elapsed: const Duration(milliseconds: 17),
              width: 160,
              height: 100,
            );
            expect(lab.presentation!.isReady, isTrue);
            expect(lab.simulationFailure, isNull);
            expect(lab.host.clock.tick, 1);
            expect(
              lab.host.layers.layer(lab.ocean.surfaceLayerId).status.data.name,
              'ready',
            );
            stdout.writeln(
              'Scene ${definition.id}: ${lab.presentation!.view!.patchCount} patches, ${lab.presentation!.controller!.estimatedBytes} planned bytes',
            );
          } finally {
            await engine.dispose();
          }
          expect((await backend.resourceStats()).liveAllocations, 0);
          expect((await backend.graphStats()).liveGraphs, 0);
        }
      } finally {
        await backend.close();
        await coast.close();
        await directory.delete(recursive: true);
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
