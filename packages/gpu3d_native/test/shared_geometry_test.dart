import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'shared views upload once, retain hidden geometry and close independently',
    () async {
      final first = await NativeBackend.create();
      final second = first.createView();
      final mesh = Mesh(
        BoxGeometry(),
        UnlitMaterial(color: const Color3(1, 0, 0)),
      );
      final scene = Scene()..add(mesh);
      FrameSubmission frame() => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(31, 31),
      );
      try {
        final outputs = await Future.wait([
          first.render(frame()),
          second.render(frame()),
        ]);
        expect(
          outputs.map((o) => o.stats.uploadedBytes).reduce((a, b) => a + b),
          720,
        );
        expect((await first.resourceStats()).residentBytes, 720);
        mesh.position = const Vec3(.1, 0, 0);
        expect((await second.render(frame())).stats.uploadedBytes, 0);
        mesh.visible = false;
        await second.render(frame());
        await first.close();
        expect((await second.resourceStats()).residentBytes, 720);
        mesh.visible = true;
        final restored = await second.render(frame()) as ReadbackOutput;
        expect(restored.stats.uploadedBytes, 0);
        final center = (15 * 31 + 15) * 4;
        expect(restored.image.pixels.sublist(center, center + 4), [
          255,
          0,
          0,
          255,
        ]);
        scene.remove(mesh);
        await second.render(frame());
        expect((await second.resourceStats()).residentBytes, 0);
      } finally {
        await first.close();
        await second.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
