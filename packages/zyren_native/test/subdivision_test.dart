import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native subdivision preserves linear coverage and smooths the Loop silhouette',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()..background = const Color3(0, 0, 0);
      final camera = OrthographicCamera();
      final source = BufferGeometry(
        positions: [-.8, -.8, 0, .8, -.8, 0, 0, .8, 0],
        normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
        indices: [0, 1, 2],
      );
      Future<ReadbackOutput> render(BufferGeometry geometry) async {
        final mesh = scene.add(
          Mesh(geometry, UnlitMaterial(color: const Color3(1, 0, 0))),
        );
        final frame =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(81, 81),
                  ),
                )
                as ReadbackOutput;
        scene.remove(mesh);
        return frame;
      }

      try {
        final original = await render(source);
        final linear = await render(
          GeometryUtils.subdivide(
            source,
            levels: 3,
            mode: SubdivisionMode.linear,
            indexFormat: IndexFormat.uint16,
          ),
        );
        expect(linear.image.pixels, original.image.pixels);
        final smooth = await render(GeometryUtils.subdivide(source, levels: 2));
        int redPixels(ReadbackOutput f) => [
          for (var i = 0; i < f.image.pixels.length; i += 4) f.image.pixels[i],
        ].where((v) => v > 128).length;
        expect(redPixels(smooth), inExclusiveRange(100, redPixels(original)));
        expect(smooth.image.pixels[(40 * 81 + 40) * 4], 255);
        await backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(81, 81),
          ),
        );
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
