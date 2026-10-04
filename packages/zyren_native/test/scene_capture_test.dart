import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'GPU capture preserves HDR, isolates views and drains queued targets',
    () async {
      final backend = await NativeBackend.create(
        experimentalAppleSurfaces: true,
      );
      final scope = backend.createResourceScope();
      final capture = await backend.createCaptureView();
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
      final scene = Scene()..background = const Color3(0, 0, 0);
      scene.add(
        Mesh(
          PlaneGeometry(width: 4, height: 4),
          StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            emissive: const Color3(1, .5, .25),
            emissiveIntensity: 8,
          ),
        ),
      );
      final target = await scope.createTexture(
        TextureDescriptor(
          width: 16,
          height: 16,
          format: TextureFormat.rgba16Float,
          usage: {
            TextureUsage.sampled,
            TextureUsage.renderAttachment,
            TextureUsage.copySource,
          },
        ),
      );
      final extra = <SceneCaptureView>[];
      try {
        for (var i = 0; i < 3; i++) {
          extra.add(await backend.createCaptureView());
        }
        await expectLater(
          backend.createCaptureView(),
          throwsA(isA<ResourceException>()),
        );
        await extra.removeLast().close();
        extra.add(await backend.createCaptureView());
        final submission = FrameSubmission.capture(
          scene: scene,
          camera: camera,
          size: PhysicalSize(16, 16),
        );
        final receipt = await capture.capture(submission, target);
        expect(receipt.admission.candidateReady, isTrue);
        expect(receipt.readbackBytes, 0);
        expect(receipt.gpuTime, isNull);
        final pixels = ByteData.sublistView(await scope.readTexture(target));
        // Binary16 exact values 8, 4, 2 at the central pixel.
        final offset = (8 * 16 + 8) * 8;
        expect(
          [
            for (var c = 0; c < 3; c++)
              pixels.getUint16(offset + c * 2, Endian.little),
          ],
          [0x4800, 0x4400, 0x4000],
        );
        final main = await backend.render(submission);
        expect(main.stats.admission!.candidateReady, isTrue);
        await expectLater(
          capture.capture(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(8, 8),
            ),
            target,
          ),
          throwsArgumentError,
        );
        await expectLater(
          capture.capture(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(16, 16),
              colorPipeline: ColorPipeline(),
            ),
            target,
          ),
          throwsArgumentError,
        );
        await capture.capture(submission, target);
        await scope.close();
        await capture.close();
        await expectLater(
          capture.capture(submission, target),
          throwsStateError,
        );
      } finally {
        await capture.close();
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
