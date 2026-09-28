import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'procedural surfaces agree between native front faces and ray picking',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()..background = null;
      final camera = PerspectiveCamera(position: const Vec3(0, 1, 5));
      try {
        for (final geometry in <BufferGeometry>[
          CircleGeometry(),
          RingGeometry(),
          CylinderGeometry(),
          ConeGeometry(),
          TorusGeometry(),
          CapsuleGeometry(),
          LatheGeometry([
            const Vec2(.5, -1),
            const Vec2(1, 0),
            const Vec2(.3, 1),
          ]),
          TubeGeometry(
            CubicBezierCurve3(
              const Vec3(-1, -1, 0),
              const Vec3(1, -1, 0),
              const Vec3(-1, 1, 0),
              const Vec3(1, 1, 0),
            ),
            radius: .2,
          ),
        ]) {
          final mesh = scene.add(
            Mesh(
              geometry,
              UnlitMaterial(
                color: const Color3(1, 1, 1),
                side: MaterialSide.front,
              ),
            ),
          );
          camera.frameBounds(mesh.bounds, aspect: 1, padding: 1.2);
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(65, 65),
                    ),
                  )
                  as ReadbackOutput;
          var hits = 0;
          for (var y = 6; y < 60; y += 7) {
            for (var x = 6; x < 60; x += 7) {
              final hit = Raycaster()
                  .captureFromCamera(
                    scene,
                    camera,
                    ViewportPoint(x + .5, y + .5),
                    logicalWidth: 65,
                    logicalHeight: 65,
                  )
                  .intersectFirst();
              final alpha = output.image.pixels[(y * 65 + x) * 4 + 3];
              expect(
                alpha > 0,
                hit != null,
                reason: '${geometry.runtimeType} at $x,$y',
              );
              if (hit != null) hits++;
            }
          }
          expect(hits, greaterThan(3));
          scene.remove(mesh);
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
