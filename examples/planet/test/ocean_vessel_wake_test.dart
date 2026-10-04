import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:planet/ocean/scenes/coast_store.dart';
import 'package:planet/ocean/scenes/definition.dart';
import 'package:planet/ocean/scenes/world.dart';

void main() {
  test('moving vessel injects native wake displacement', () async {
    final directory = await Directory.systemTemp.createTemp('ocean-wake-');
    final coast = await OceanLabCoast.open(
      directory,
      allowFixtureGeneration: true,
    );
    final definition = OceanLabSceneDefinition.decode(
      File('assets/ocean/scenes.json').readAsStringSync(),
    ).singleWhere((scene) => scene.id == 'vessel');
    final backend = await NativeBackend.create();
    await backend.configureResourceBudget(768 * 1024 * 1024);
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
      await engine.render(elapsed: Duration.zero, width: 160, height: 100);
      final field = lab.presentation!.view!.configuration.interactions!;
      final before = await field.debugState();
      expect([
        for (var i = 0; i < before.length; i += 4) before[i],
      ], everyElement(0));
      await engine.render(
        elapsed: const Duration(milliseconds: 100),
        width: 160,
        height: 100,
      );
      expect(lab.simulationFailure, isNull);
      expect(lab.host.clock.tick, 6);
      expect(lab.lastWakeAdmission, OceanInteractionAdmission.accepted);
      final after = await field.debugState();
      expect(
        [for (var i = 0; i < after.length; i += 4) after[i].abs()],
        contains(greaterThan(1e-8)),
        reason:
            'Hull motion must inject ripples, independently of spray and foam.',
      );
    } finally {
      await engine.dispose();
      expect((await backend.resourceStats()).liveAllocations, 0);
      expect((await backend.graphStats()).liveGraphs, 0);
      await backend.close();
      await coast.close();
      await directory.delete(recursive: true);
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
}
