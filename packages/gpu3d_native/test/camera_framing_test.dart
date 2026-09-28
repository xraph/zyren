import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'framed meshes produce native pixels under both projections and aspects',
    () async {
      final backend = await NativeBackend.create();
      const origin = Vec3(6378137, -6378137, 6378137);
      final scene = Scene()..background = const Color3(0, 0, 0);
      final geometry = BoxGeometry();
      final meshes = [
        for (final (offset, color) in [
          (const Vec3(-3, -1, 0), const Color3(1, 0, 0)),
          (const Vec3(0, 1, -2), const Color3(0, 1, 0)),
          (const Vec3(3, 0, 2), const Color3(0, 0, 1)),
        ])
          scene.add(
            Mesh(geometry, UnlitMaterial(color: color))
              ..position = origin + offset,
          ),
      ];
      final bounds = meshes.fold(
        const Bounds3.empty(),
        (bounds, mesh) =>
            bounds.union(mesh.bounds.transformed(mesh.worldMatrix)),
      );
      try {
        for (final camera in <Camera>[
          PerspectiveCamera(),
          OrthographicCamera(zoom: 2),
        ]) {
          for (final size in [PhysicalSize(200, 100), PhysicalSize(100, 200)]) {
            final aspect = size.width / size.height;
            camera.frameBounds(bounds, aspect: aspect, padding: 1.3);
            final frame =
                await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: size,
                      ),
                    )
                    as ReadbackOutput;
            expect(frame.stats.drawCalls, 3);
            final m = camera.viewProjection(aspect).storage;
            for (var i = 0; i < meshes.length; i++) {
              final p = meshes[i].position - camera.position;
              double component(int row) =>
                  m[row] * p.x +
                  m[row + 4] * p.y +
                  m[row + 8] * p.z +
                  m[row + 12];
              final x = ((component(0) / component(3) + 1) * .5 * size.width)
                  .floor();
              final y = ((1 - component(1) / component(3)) * .5 * size.height)
                  .floor();
              final pixel = (y * size.width + x) * 4;
              expect(frame.image.pixels.sublist(pixel, pixel + 4), [
                for (var c = 0; c < 3; c++) c == i ? 255 : 0,
                255,
              ]);
            }
          }
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
