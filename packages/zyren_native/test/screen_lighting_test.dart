import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'scene_admission_test.dart' show largeGeometry;
import 'support/environment_checks.dart'
    show constantEnvironment, smallEnvironment;

Scene sceneFixture() => Scene()
  ..background = const Color3(0, 0, 0)
  ..add(
    Mesh(
        PlaneGeometry(width: 8, height: 6),
        StandardMaterial(metallic: 1, roughness: .02),
      )
      ..rotateX(-math.pi / 2)
      ..position = const Vec3(0, -1, -4),
  )
  ..add(
    Mesh(
      PlaneGeometry(width: 2, height: 2),
      StandardMaterial(
        baseColor: const Color3(0, 0, 0),
        emissive: const Color3(1, 0, 0),
      ),
    )..position = const Vec3(0, 0, -4),
  );
final camera = PerspectiveCamera(
  position: Vec3.zero,
  target: const Vec3(0, 0, -1),
  fieldOfView: 1.1,
  near: .1,
  far: 30,
);
FrameSubmission frame(Scene scene, {int size = 96, Environment? environment}) =>
    FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(size, size),
      environment: environment,
    );
int sum(ImageData image, int channel) => [
  for (var i = channel; i < image.pixels.length; i += 4) image.pixels[i],
].fold(0, (a, b) => a + b);
ScreenSpaceLighting lighting() => ScreenSpaceLighting(
  reflections: true,
  quality: ScreenSpaceQuality.high,
  maxDistance: 8,
);
Future<NativeBackend> createBackend() async {
  try {
    return await NativeBackend.create();
  } on SceneException catch (error) {
    print("native startup cause: ${error.issue.cause}");
    rethrow;
  }
}

void main() {
  test(
    'public settings use mapped inputs and replace selected environment radiance',
    () async {
      final backend = await createBackend();
      final scope = GpuScope.fromBackend(backend);
      final probes = await ReflectionProbes.create(backend);
      try {
        final scene = sceneFixture();
        final receiver = scene.children.whereType<Mesh>().first;
        Future<ReadbackOutput> render({Environment? environment}) async =>
            await backend.render(frame(scene, environment: environment))
                as ReadbackOutput;
        final baseline = await render();
        scene.renderSettings = RenderSettings(screenSpaceLighting: lighting());
        final reflected = await render();
        expect(
          sum(reflected.image, 0),
          greaterThan(sum(baseline.image, 0) + 10000),
        );
        expect(
          reflected.stats.profile!.passes['screenLightingSource']!.drawCalls,
          2,
        );
        expect(reflected.stats.profile!.screenLightingReflectionSteps, 64);
        expect(reflected.stats.profile!.screenLightingBytes, 96 * 96 * 12);
        receiver.material = StandardMaterial(
          metallic: 1,
          roughness: .02,
          normalMap: TextureMap(
            image: TextureImage.rgba(
              width: 1,
              height: 1,
              format: TextureFormat.rgba8Unorm,
              pixels: Uint8List.fromList([255, 128, 128, 255]),
            ),
          ),
        );
        final mapped = await render();
        expect(sum(mapped.image, 0), lessThan(sum(reflected.image, 0) - 10000));
        receiver.material = StandardMaterial(
          metallic: 1,
          roughness: .02,
          metallicRoughnessMap: TextureMap(
            image: TextureImage.rgba(
              width: 1,
              height: 1,
              format: TextureFormat.rgba8Unorm,
              pixels: Uint8List.fromList([0, 255, 255, 255]),
            ),
          ),
        );
        final restored = await render();
        expect(restored.image.pixels, reflected.image.pixels);
        scene.children.whereType<Mesh>().last.material = UnlitMaterial(
          color: const Color3(1, 0, 0),
        );
        final map = await EnvironmentMap.fromEquirectangular(
          constantEnvironment(0, 1, 0),
          resources: scope.resources,
          quality: smallEnvironment,
        );
        final environment = Environment(map: map);
        scene.renderSettings = RenderSettings();
        final fallback = await render(environment: environment);
        scene.renderSettings = RenderSettings(screenSpaceLighting: lighting());
        final replaced = await render(environment: environment);
        var hits = 0, misses = 0;
        for (var i = 0; i < replaced.image.pixels.length; i += 4) {
          if (reflected.image.pixels[i] > 200 &&
              baseline.image.pixels[i] == 0) {
            hits++;
            expect(
              replaced.image.pixels[i + 1],
              lessThan(3),
              reason: 'accepted hit retained green environment energy',
            );
          } else if (fallback.image.pixels[i + 1] > 200 &&
              reflected.image.pixels[i] == 0) {
            misses++;
            expect(replaced.image.pixels[i + 1], fallback.image.pixels[i + 1]);
          }
        }
        expect(hits, greaterThan(100));
        expect(misses, greaterThan(100));
        print(
          'public mapped receiver and environment replacement: hits=$hits misses=$misses',
        );
        final room = Scene()
          ..add(
            Mesh(
              BoxGeometry(width: 20, height: 20, depth: 20),
              UnlitMaterial(color: const Color3(0, 0, 1)),
            )..position = const Vec3(0, -1, -4),
          );
        await probes.update(
          ReflectionProbeDescriptor(
            id: 0,
            position: const Vec3(0, -1, -4),
            bounds: Bounds3(
              const Vec3(-.1, -1.1, -4.1),
              const Vec3(.1, -.9, -3.9),
            ),
            faceSize: 16,
            quality: smallEnvironment,
          ),
          scene: room,
          contentRevision: 1,
        );
        while (probes.pending) {
          await probes.advance();
        }
        scene.reflectionProbes = probes;
        scene.renderSettings = RenderSettings();
        final localFallback = await render(environment: environment);
        scene.renderSettings = RenderSettings(screenSpaceLighting: lighting());
        final localReplaced = await render(environment: environment);
        var localHits = 0, localMisses = 0;
        for (var i = 0; i < localReplaced.image.pixels.length; i += 4) {
          if (reflected.image.pixels[i] > 200 &&
              baseline.image.pixels[i] == 0) {
            localHits++;
            expect(localReplaced.image.pixels[i + 2], lessThan(3));
          } else if (localFallback.image.pixels[i + 2] > 200 &&
              reflected.image.pixels[i] == 0) {
            localMisses++;
            expect(
              localReplaced.image.pixels[i + 2],
              localFallback.image.pixels[i + 2],
            );
          }
        }
        expect(localHits, greaterThan(100));
        expect(localMisses, greaterThan(100));
        print(
          'selected local probe replacement: hits=$localHits misses=$localMisses',
        );
      } finally {
        await probes.close();
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'staged and failed candidates use current retained inputs; queued views retire scratch',
    () async {
      final backend = await createBackend();
      final control = backend.createView();
      final scope = GpuScope.fromBackend(backend);
      final capture = await backend.createCaptureView();
      try {
        final scene = sceneFixture()
          ..renderSettings = RenderSettings(screenSpaceLighting: lighting());
        final initial = await backend.render(frame(scene)) as ReadbackOutput;
        await control.render(frame(scene));
        backend.configureSceneUploadBudget(64 * 1024);
        final candidate = sceneFixture()
          ..renderSettings = RenderSettings(screenSpaceLighting: lighting());
        (candidate.children.whereType<Mesh>().last).material = StandardMaterial(
          emissive: const Color3(0, 1, 0),
        );
        for (var i = 0; i < 2; i++) {
          candidate.add(
            Mesh(largeGeometry(5000), UnlitMaterial())
              ..position = Vec3(100.0 + i, 0, 0),
          );
        }
        final pending = frame(candidate);
        final staged = await backend.render(pending) as ReadbackOutput;
        expect(staged.stats.admission!.candidateReady, isFalse);
        expect(staged.image.pixels, initial.image.pixels);
        camera.position = const Vec3(.15, .1, 0);
        try {
          final moving =
              await backend.render(frame(candidate)) as ReadbackOutput;
          expect(moving.stats.admission!.candidateReady, isFalse);
          final expected = await control.render(frame(scene)) as ReadbackOutput;
          expect(moving.image.pixels, expected.image.pixels);
        } finally {
          camera.position = Vec3.zero;
        }
        await expectLater(
          backend.render(frame(scene, size: 4096)),
          throwsA(isA<SceneException>()),
        );
        final restored = await backend.render(frame(scene)) as ReadbackOutput;
        expect(restored.image.pixels, initial.image.pixels);
        for (final size in [32, 40, 48, 32]) {
          final target = await scope.resources.createTexture(
            TextureDescriptor(
              width: size,
              height: size,
              format: TextureFormat.rgba16Float,
              usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
            ),
          );
          final receipt = await capture.capture(
            frame(scene, size: size),
            target,
          );
          expect(receipt.readbackBytes, 0);
          expect(receipt.attachmentBytes, size * size * 4);
          expect(
            (await backend.inspectGpu()).frameProfile!.screenLightingBytes,
            size * size * 12,
          );
          // Resize after queue admission, without a CPU readback of the capture.
          await control.render(frame(scene, size: size + 1));
        }
        print(
          'staged retained camera matched control; queued capture sizes 32/40/48/32 retired across views',
        );
        final bytes =
            (await backend.inspectGpu()).frameProfile!.screenLightingBytes;
        await capture.close();
        expect(
          (await backend.inspectGpu()).frameProfile!.screenLightingBytes,
          bytes,
          reason: 'closing a nonowner retired another view scratch',
        );
        await control.close();
        expect(
          (await backend.inspectGpu()).frameProfile!.screenLightingBytes,
          0,
        );
      } finally {
        await capture.close();
        await control.close();
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
