import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'GPU environment convolution lights standard materials and owns its scope',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      final shaders = backend.createShaderCompiler();
      final graphs = backend.createGraphCompiler();
      try {
        final source = await resources.createTexture(
          TextureDescriptor(
            width: 8,
            height: 4,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await resources.writeTexture(
          source,
          Float32List.fromList([
            for (var i = 0; i < 32; i++) ...[2.0, 1.0, .5, 1.0],
          ]).buffer.asUint8List(),
        );
        final environment = await EnvironmentMap.generate(
          resources: resources,
          shaders: shaders,
          graphs: graphs,
          source: source,
          resolution: 16,
          roughnessLevels: 4,
          samples: 1024,
          brdfSize: 32,
        );
        final lut = ByteData.sublistView(
          await resources.readTexture(environment.brdf),
        );
        double half(ByteData data, int byte) {
          final h = data.getUint16(byte, Endian.little),
              e = (h >> 10) & 31,
              m = h & 1023;
          return (h & 32768 == 0 ? 1 : -1) *
              (e == 0
                  ? math.pow(2, -14) * (m / 1024)
                  : math.pow(2, e - 15) * (1 + m / 1024));
        }

        final reference =
            jsonDecode(
                  File(
                    '../../test_assets/rendering/pbr/environment.json',
                  ).readAsStringSync(),
                )
                as Map;
        for (final sample in reference['samples'] as List) {
          final offset = ((sample['y'] as int) * 32 + (sample['x'] as int)) * 8;
          for (var channel = 0; channel < 2; channel++) {
            expect(
              half(lut, offset + 2 * channel),
              closeTo(sample['brdf'][channel], .012),
              reason: '$sample channel $channel',
            );
          }
        }
        for (final texture in [environment.irradiance, environment.specular]) {
          final data = ByteData.sublistView(
            await resources.readTexture(texture),
          );
          for (var i = 0; i < data.lengthInBytes; i += 8) {
            for (var c = 0; c < 3; c++) {
              expect(
                half(data, i + c * 2),
                closeTo(
                  [2.0, 1.0, .5][c] *
                      (identical(texture, environment.irradiance)
                          ? math.pi
                          : 1),
                  .007,
                ),
              );
            }
          }
        }
        final scene = Scene()
          ..background = const Color3(0, 0, 0)
          ..renderSettings = RenderSettings(
            environment: environment,
            toneMapping: ToneMapping.reinhard,
          );
        final mesh = scene.add(
          Mesh(
            PlaneGeometry(width: 2, height: 2),
            StandardMaterial(baseColor: const Color3(.5, .5, .5), roughness: 1),
          ),
        );
        final camera = OrthographicCamera(
          left: -1,
          right: 1,
          top: 1,
          bottom: -1,
          near: 0,
          far: 10,
          position: const Vec3(0, 0, 3),
        );
        Future<List<int>> pixel() async {
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(33, 33),
                    ),
                  )
                  as ReadbackOutput;
          return output.image.pixels.sublist(
            16 * 33 * 4 + 16 * 4,
            16 * 33 * 4 + 16 * 4 + 4,
          );
        }

        final oldGraph = graphs.active;
        final resident = (await backend.resourceStats()).residentBytes;
        await expectLater(
          EnvironmentMap.generate(
            resources: resources,
            shaders: shaders,
            graphs: graphs,
            source: source,
            resolution: 256,
          ),
          throwsArgumentError,
        );
        expect(graphs.active, same(oldGraph));
        expect((await backend.resourceStats()).residentBytes, resident);
        final lit = await pixel();
        expect(lit[0], inInclusiveRange(187, 190));
        expect(lit[1], inInclusiveRange(156, 159));
        expect(lit[2], inInclusiveRange(123, 127));
        mesh.material = StandardMaterial(
          baseColor: const Color3(0, 0, 0),
          metallic: 1,
          roughness: 1,
        );
        expect((await pixel())[0], lessThan(8));
        final directional = Float32List.fromList([
          for (var y = 0; y < 4; y++)
            for (var x = 0; x < 8; x++) ...[
              x == 5 || x == 6 ? 4.0 : 0.0,
              0.0,
              0.0,
              1.0,
            ],
        ]);
        await resources.writeTexture(source, directional.buffer.asUint8List());
        await graphs.active!.execute();
        final filtered = ByteData.sublistView(
          await resources.readTexture(environment.specular),
        );
        double level(int x, int z) =>
            half(filtered, ((z * 16 + 8) * 32 + x) * 8);
        expect(level(24, 0), greaterThan(3.8));
        expect(level(16, 0), lessThan(.1));
        expect(level(24, 3), lessThan(level(24, 0) - .3));
        expect(level(16, 3), greaterThan(level(16, 0) + .3));
        mesh.material = StandardMaterial(
          baseColor: const Color3(1, 1, 1),
          metallic: 1,
          roughness: .1,
        );
        final bright = await pixel();
        scene.renderSettings = RenderSettings(
          environment: EnvironmentMap(
            irradiance: environment.irradiance,
            specular: environment.specular,
            brdf: environment.brdf,
            rotation: math.pi,
          ),
          toneMapping: ToneMapping.reinhard,
        );
        expect((await pixel())[0], lessThan(bright[0] - 100));
        scene.renderSettings = RenderSettings(
          toneMapping: ToneMapping.reinhard,
        );
        expect(await pixel(), [0, 0, 0, 255]);
        await graphs.close();
        await shaders.close();
        await resources.close();
        scene.remove(mesh);
        await pixel();
        expect((await backend.resourceStats()).residentBytes, 0);
        scene.renderSettings = RenderSettings(environment: environment);
        await expectLater(
          pixel(),
          throwsA(
            isA<SceneException>().having(
              (e) => e.issue.cause,
              "cause",
              isA<StateError>(),
            ),
          ),
        );
      } finally {
        await graphs.close();
        await shaders.close();
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
  test(
    'lighting plugin publishes and unregisters GPU resources through public hooks',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene()
        ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
      scene.add(Mesh(PlaneGeometry(width: 2, height: 2), StandardMaterial()));
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        backendFactory: () async => backend,
        plugins: [
          EnvironmentLightingPlugin(
            EnvironmentImage(
              width: 2,
              height: 1,
              pixels: Float32List.fromList([1, 1, 1, 1, 1, 1, 1, 1]),
            ),
            resolution: 4,
            samples: 32,
            brdfSize: 8,
          ),
        ],
      );
      try {
        expect(scene.environment, isNotNull);
        await engine.render(elapsed: Duration.zero, width: 24, height: 24);
      } finally {
        await engine.dispose();
      }
      expect(scene.environment, isNull);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
