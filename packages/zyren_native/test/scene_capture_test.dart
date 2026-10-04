import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test('transparent generic capture returns straight-alpha HDR color', () async {
    final backend = await NativeBackend.create();
    final resources = backend.createResourceScope();
    final capture = await backend.createCaptureView();
    try {
      final scene = Scene()..ambient = 0;
      scene.add(
        Mesh(
          PlaneGeometry(width: 2, height: 2),
          StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            emissive: const Color3(1, .5, .25),
            emissiveIntensity: 8,
            opacity: .5,
            alphaMode: MaterialAlphaMode.blend,
          ),
        ),
      );
      final target = await resources.createTexture(
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
      await capture.capture(
        FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(position: const Vec3(0, 0, 3)),
          size: PhysicalSize(16, 16),
        ),
        target,
      );
      final pixels = ByteData.sublistView(await resources.readTexture(target));
      final center = (8 * 16 + 8) * 8;
      // Straight RGB remains 8/4/2 at alpha 0.5; associated RGB would be 4/2/1.
      for (final (channel, value) in [0x4800, 0x4400, 0x4000, 0x3800].indexed) {
        expect(
          pixels.getUint16(center + channel * 2, Endian.little),
          closeTo(value, 2),
        );
      }
      for (var channel = 0; channel < 4; channel++) {
        expect(pixels.getUint16(channel * 2, Endian.little), 0);
      }
    } finally {
      await capture.close();
      await resources.close();
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

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
        expect(receipt.sharedEnergyLutBytes, 131072);
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
