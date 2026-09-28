import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'spatial filtering softens diagonal coverage without dimming straight color',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final view = backend.createView();
      final effect = PostProcessing();
      final scene = Scene()..background = null;
      scene.add(
        Mesh(
          BufferGeometry(
            positions: [-.72, -.69, 0, .77, -.65, 0, .01, .83, 0],
            normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
            indices: [0, 1, 2],
          ),
          UnlitMaterial(color: const Color3(1, 1, 1)),
        ),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: OrthographicCamera(verticalSize: 2),
        backendFactory: () async => view,
        plugins: [effect],
        onIssue: (issue) => fail(issue.toString()),
      );
      Future<ReadbackOutput> draw() async =>
          await engine.renderFrame(
                elapsed: Duration.zero,
                width: 31,
                height: 31,
                colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
              )
              as ReadbackOutput;
      try {
        final plain = await draw();
        expect(
          List.generate(
            31 * 31,
            (i) => plain.image.pixels[i * 4 + 3],
          ).every((a) => a == 0 || a == 255),
          isTrue,
        );
        effect.antialias = true;
        final filtered = await draw();
        final edge = <List<int>>[];
        for (var i = 0; i < filtered.image.pixels.length; i += 4) {
          final p = filtered.image.pixels.sublist(i, i + 4);
          if (p[3] > 0 && p[3] < 255) edge.add(p);
        }
        expect(edge.length, greaterThan(20));
        expect(edge.every((p) => p.take(3).every((v) => v >= 253)), isTrue);
        effect.antialias = false;
        expect((await draw()).image.pixels, plain.image.pixels);
      } finally {
        await engine.dispose();
      }
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'effect allocation rejects oversize candidates and recovers without leaked resources',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final effect = PostProcessing(
        bloom: BloomOptions(),
        maxIntermediateBytes: 8192,
      );
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        backendFactory: () async => backend.createView(),
        plugins: [effect],
        onIssue: (issue) => fail(issue.toString()),
      );
      Future<FrameOutput> draw(int size) => engine.renderFrame(
        elapsed: Duration.zero,
        width: size,
        height: size,
        colorPipeline: ColorPipeline(),
      );
      try {
        await draw(16);
        final good = await backend.resourceStats();
        await expectLater(
          draw(64),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.cause,
              'cause',
              isA<ResourceException>().having(
                (e) => e.code,
                'code',
                ResourceErrorCode.budgetExceeded,
              ),
            ),
          ),
        );
        final after = await backend.resourceStats();
        expect(after.residentBytes, good.residentBytes);
        expect(after.liveAllocations, good.liveAllocations);
        await draw(16);
        await expectLater(
          engine.renderFrame(elapsed: Duration.zero, width: 15, height: 15),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.cause,
              'cause',
              isA<StateError>(),
            ),
          ),
        );
        await draw(16);
      } finally {
        await engine.dispose();
      }
      expect((await backend.resourceStats()).residentBytes, 0);
      await backend.close();
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'bloom spreads HDR light, respects alpha, updates and releases targets',
    () async {
      final backend = await NativeBackend.create();
      addTearDown(backend.close);
      final effect = PostProcessing(
        bloom: BloomOptions(threshold: 1, intensity: 1, radius: 1),
      );
      final scene = Scene()..background = null;
      scene.add(
        Mesh(
          PlaneGeometry(width: .08, height: .08),
          StandardMaterial(
            baseColor: const Color3(0, 0, 0),
            emissive: const Color3(1, 1, 1),
            emissiveIntensity: 8,
          ),
        ),
      );
      final camera = OrthographicCamera(verticalSize: 2)
        ..position = const Vec3(0, 0, 3);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [effect],
        onIssue: (issue) => fail(issue.toString()),
      );
      Future<ReadbackOutput> draw([int size = 33]) async =>
          await engine.renderFrame(
                elapsed: Duration.zero,
                width: size,
                height: size,
                colorPipeline: ColorPipeline(
                  toneMapping: ToneMapping.reinhard,
                  sampleCount: 4,
                ),
              )
              as ReadbackOutput;
      try {
        final bloom = await draw();
        expect(bloom.image.pixels.where((v) => v > 0), isNotEmpty);
        int alphaCount(ReadbackOutput frame) => List.generate(
          frame.image.pixels.length ~/ 4,
          (i) => frame.image.pixels[i * 4 + 3],
        ).where((a) => a > 0).length;
        final resident = (await backend.resourceStats()).residentBytes;
        effect.bloom = BloomOptions(threshold: 20);
        final below = await draw();
        expect(alphaCount(bloom), greaterThan(alphaCount(below) + 30));
        expect((await backend.resourceStats()).residentBytes, resident);
        expect(below.stats.uploadedBytes, 0);
        effect.bloom = null;
        final plain = await draw();
        expect(below.image.pixels, plain.image.pixels);
        expect(
          (await backend.resourceStats()).residentBytes,
          lessThan(resident),
        );
        effect.bloom = BloomOptions(intensity: 0);
        expect((await draw()).image.pixels, plain.image.pixels);
        effect.bloom = BloomOptions();
        effect.antialias = true;
        await draw(47);
        await draw(33);
        effect.bloom = null;
        effect.antialias = false;
        expect((await draw()).image.pixels, plain.image.pixels);
      } finally {
        await engine.dispose();
      }
      expect((await backend.resourceStats()).residentBytes, 0);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
