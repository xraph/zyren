import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'Dart isolate renders native pixels and disposes deterministically',
    () async {
      final renderer = await NativeRenderer.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        scene.add(
          Mesh(BoxGeometry(), UnlitMaterial(color: const Color3(1, 0, 0))),
        );
        final camera = PerspectiveCamera();
        final frame = await renderer.render(
          scene,
          camera,
          width: 63,
          height: 47,
        );
        final center = (23 * 63 + 31) * 4;
        expect(frame.pixels.sublist(center, center + 4), [255, 0, 0, 255]);
        expect(frame.pixels.sublist(0, 4), [0, 0, 0, 255]);
        scene.children.single.visible = false;
        final empty = await renderer.render(
          scene,
          camera,
          width: 63,
          height: 47,
        );
        expect(empty.pixels.sublist(center, center + 4), [0, 0, 0, 255]);
        scene.children.single.visible = true;
        final restored = await renderer.render(
          scene,
          camera,
          width: 63,
          height: 47,
        );
        expect(restored.pixels.sublist(center, center + 4), [255, 0, 0, 255]);
        expect(
          (await renderer.render(
            scene,
            camera,
            width: 80,
            height: 60,
          )).pixels.length,
          80 * 60 * 4,
        );
        final flight = renderer.render(scene, camera, width: 64, height: 64);
        await expectLater(
          renderer.render(scene, camera, width: 64, height: 64),
          throwsStateError,
        );
        await flight;
        final pending = renderer.render(scene, camera, width: 64, height: 64);
        final closing = renderer.dispose();
        expect((await pending).pixels.length, 64 * 64 * 4);
        await closing;
      } finally {
        await renderer.dispose();
      }
      await renderer.dispose();
      await expectLater(
        renderer.render(Scene(), PerspectiveCamera(), width: 1, height: 1),
        throwsStateError,
      );
    },
    skip:
        Platform.environment['RUN_NATIVE_GPU'] != '1' &&
        !const bool.fromEnvironment('RUN_NATIVE_GPU'),
  );
}
