import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'screen effects plugin resizes and publishes complete settings only',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()
        ..background = const Color3(.2, .3, .4)
        ..renderSettings = RenderSettings(
          toneMapping: ToneMapping.agx,
          exposure: 2,
        );
      final plugin = ScreenEffectsPlugin(
        settings: ScreenEffectsSettings(lens: LensFlareSettings()),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      try {
        await engine.render(elapsed: Duration.zero, width: 64, height: 48);
        expect(scene.effects.length, 26);
        expect(plugin.controller.generation, 1);
        final first = (await backend.resourceStats()).residentBytes;
        await engine.render(elapsed: Duration.zero, width: 64, height: 48);
        expect(plugin.controller.generation, 1);
        expect((await backend.resourceStats()).residentBytes, first);
        await engine.render(elapsed: Duration.zero, width: 65, height: 49);
        expect(plugin.controller.width, 65);
        expect(plugin.controller.height, 49);
        expect(plugin.controller.generation, 2);
        final oldSettings = plugin.controller.settings,
            oldStages = scene.effects;
        final extras = [
          for (var i = 0; i < 6; i++) scene.addEffect(scene.effects.last),
        ];
        final lut = HaldLookup.fromImage(
          ImageData(size: PhysicalSize(8, 8), pixels: Uint8List(8 * 8 * 4)),
        );
        await expectLater(
          plugin.controller.setSettings(
            ScreenEffectsSettings(lens: LensFlareSettings(), grading: lut),
          ),
          throwsStateError,
        );
        expect(plugin.controller.settings, same(oldSettings));
        expect(scene.effects.length, 32);
        expect(scene.effects, containsAll(oldStages));
        for (final e in extras) {
          e.dispose();
        }
        await expectLater(
          engine.render(elapsed: Duration.zero, width: 4096, height: 4096),
          throwsArgumentError,
        );
        expect(plugin.controller.width, 65);
        await engine.render(elapsed: Duration.zero, width: 65, height: 49);
        await Future.wait([
          plugin.controller.setSettings(
            ScreenEffectsSettings(smaa: SmaaPreset.high),
          ),
          plugin.controller.setSettings(
            ScreenEffectsSettings(smaa: null, dithering: false),
          ),
        ]);
        expect(scene.effects, isEmpty);
        expect(plugin.controller.settings.smaa, isNull);
        expect(scene.renderSettings.toneMapping, ToneMapping.agx);
        expect(scene.renderSettings.exposure, 2);
        await engine.dispose();
        expect(scene.effects, isEmpty);
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveMaterials, 0);
        await expectLater(
          plugin.controller.setSettings(ScreenEffectsSettings()),
          throwsStateError,
        );
      } finally {
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
