import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import 'package:test/test.dart';
import 'support/native_checks.dart';

void main() {
  final skip = Platform.environment['RUN_NATIVE_GPU'] != '1';
  test(
    'two passes, uniform edits, resize, bypass and retirement on native GPU',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyEffects(backend);
      } finally {
        await backend.close();
      }
    },
    skip: skip,
  );
  test(
    'shared scenes have independent effects and reattachment rebuilds resources',
    () async {
      final observer = await NativeBackend.create();
      final scene = Scene()..background = const Color3(1, 0, 0);
      final first = EffectsPlugin(
        options: EffectsOptions(saturation: 0, vignette: 0),
      );
      final second = EffectsPlugin(options: EffectsOptions(vignette: 0));
      Future<SceneEngine> engine(EffectsPlugin plugin) => SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: () async => observer.createView(),
        plugins: [plugin],
      );
      Future<ReadbackOutput> draw(SceneEngine view, int w) async =>
          await view.renderFrame(elapsed: Duration.zero, width: w, height: 13)
              as ReadbackOutput;
      final a = await engine(first), b = await engine(second);
      SceneEngine? recovered;
      try {
        await draw(a, 17);
        final red = await draw(b, 29);
        expect(red.image.pixels.sublist(0, 4), [255, 0, 0, 255]);
        expect((await observer.graphStats()).liveGraphs, 2);
        await a.dispose();
        expect((await observer.graphStats()).liveGraphs, 1);
        expect((await draw(b, 29)).image.pixels.sublist(0, 4), [
          255,
          0,
          0,
          255,
        ]);
        recovered = await engine(first);
        final gray = await draw(recovered, 7);
        expect(gray.image.pixels[0], closeTo(srgb(.2126), 2));
        expect(first.state.graphBuilds, 1);
        expect(first.state.size!.width, 7);
      } finally {
        await a.dispose();
        await b.dispose();
        await recovered?.dispose();
        expect((await observer.resourceStats()).residentBytes, 0);
        await observer.close();
      }
    },
    skip: skip,
  );
}
