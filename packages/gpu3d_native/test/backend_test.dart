import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

class _UnknownSurface implements SurfaceKey {}

void main() {
  test(
    'backend preserves a captured scene and never silently falls back from a surface',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final mesh = Mesh(
          BoxGeometry(),
          MeshMaterial(color: const Color3(1, 0, 0), unlit: true),
        );
        scene.add(mesh);
        final camera = PerspectiveCamera();
        final frame = FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: PhysicalSize(63, 47),
        );
        mesh.visible = false;
        final output = await backend.render(frame);
        expect(output, isA<ReadbackOutput>());
        final readback = output as ReadbackOutput;
        final center = (23 * 63 + 31) * 4;
        expect(readback.image.pixels.sublist(center, center + 4), [
          255,
          0,
          0,
          255,
        ]);
        expect(readback.stats.readbackBytes, 63 * 47 * 4);
        expect(readback.stats.triangles, 12);
        expect(readback.stats.gpuTime, isNull);
        expect(
          backend.capabilities.supports(RenderFeature.sharedTexture),
          isFalse,
        );
        await expectLater(
          backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(8, 8),
              target: SurfaceTarget(_UnknownSurface(), 1),
            ),
          ),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.code,
              'code',
              'presentationUnavailable',
            ),
          ),
        );
        final empty =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(63, 47),
                  ),
                )
                as ReadbackOutput;
        expect(empty.image.pixels.sublist(center, center + 4), [0, 0, 0, 255]);
      } finally {
        await backend.close();
      }
      await backend.close();
      await expectLater(
        backend.render(
          FrameSubmission.capture(
            scene: Scene(),
            camera: PerspectiveCamera(),
            size: PhysicalSize(1, 1),
          ),
        ),
        throwsA(
          isA<SceneException>().having((e) => e.issue.code, 'code', 'disposed'),
        ),
      );
    },
    skip:
        Platform.environment['RUN_NATIVE_GPU'] != '1' &&
        !const bool.fromEnvironment('RUN_NATIVE_GPU'),
  );
}
