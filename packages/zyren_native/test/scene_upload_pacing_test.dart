import 'dart:io';

import 'package:test/test.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'paced native uploads retain pixels until the complete replacement arrives',
    () async {
      final backend = await NativeBackend.create();
      try {
        backend.configureSceneUploadBudget(400);
        final camera = PerspectiveCamera();
        Future<ReadbackOutput> draw(Scene scene) async =>
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(16, 16),
                  ),
                )
                as ReadbackOutput;
        final previous = Scene()
          ..add(
            Mesh(PlaneGeometry(), UnlitMaterial(color: const Color3(1, 0, 0))),
          );
        final initial = await draw(previous);
        final center = (8 * 16 + 8) * 4;
        expect(initial.image.pixels.sublist(center, center + 4), [
          255,
          0,
          0,
          255,
        ]);
        final candidate = Scene();
        for (var i = 0; i < 5; i++) {
          candidate.add(
            Mesh(PlaneGeometry(), UnlitMaterial(color: const Color3(0, 1, 0))),
          );
        }
        for (var i = 0; i < 3; i++) {
          camera.position = Vec3(.01 * i, 0, 5);
          final output = await draw(candidate);
          expect(output.stats.uploadedBytes, lessThanOrEqualTo(400));
          expect(output.stats.admission!.candidateReady, i == 2);
          expect(
            output.image.pixels.sublist(center, center + 4),
            i == 2 ? [0, 255, 0, 255] : [255, 0, 0, 255],
          );
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
