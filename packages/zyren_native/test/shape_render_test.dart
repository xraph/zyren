import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'shape holes and beveled walls render through the native geometry path',
    () async {
      final backend = await NativeBackend.create();
      try {
        final shape = Shape2D(
          const [Vec2(-1, -1), Vec2(1, -1), Vec2(1, 1), Vec2(-1, 1)],
          holes: const [
            [Vec2(-.3, -.3), Vec2(.3, -.3), Vec2(.3, .3), Vec2(-.3, .3)],
          ],
        );
        for (final geometry in [
          ShapeGeometry(shape),
          ExtrudeGeometry(shape, depth: .5, bevelSize: .1, bevelSegments: 3),
        ]) {
          final scene = Scene()..background = const Color3(0, 0, 0);
          scene.add(
            Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0))),
          );
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: OrthographicCamera(
                        position: const Vec3(0, 0, 3),
                        verticalSize: 3,
                      ),
                      size: PhysicalSize(31, 31),
                    ),
                  )
                  as ReadbackOutput;
          expect(output.image.pixels.sublist(1920, 1924), [0, 0, 0, 255]);
          expect(
            output.image.pixels.sublist(
              (15 * 31 + 7) * 4,
              (15 * 31 + 7) * 4 + 4,
            ),
            [255, 0, 0, 255],
          );
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
