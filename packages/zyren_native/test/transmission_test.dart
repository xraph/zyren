import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

int srgb(double v) =>
    ((v <= .0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - .055) * 255)
        .round();
TextureMap dataMap(int r, int g) => TextureMap(
  image: TextureImage.rgba(
    width: 1,
    height: 1,
    format: TextureFormat.rgba8Unorm,
    pixels: Uint8List.fromList([r, g, 0, 255]),
  ),
);
void main() {
  test('inactive volume preserves opaque double-sided backfaces', () async {
    final backend = await NativeBackend.create();
    try {
      final scene = Scene()..background = const Color3(1, 1, 1);
      final mesh = scene.add(
        Mesh(PlaneGeometry(width: 4, height: 4), PhysicalMaterial())
          ..rotateY(math.pi),
      );
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
      for (final material in [
        PhysicalMaterial(thickness: 1, baseColor: const Color3(0, 0, 0)),
        PhysicalMaterial(
          thickness: 1,
          transmission: 1,
          transmissionMap: dataMap(0, 255),
          baseColor: const Color3(0, 0, 0),
        ),
        PhysicalMaterial(
          thickness: 1,
          transmission: 1,
          metallic: 1,
          baseColor: const Color3(0, 0, 0),
        ),
      ]) {
        mesh.material = material;
        final image =
            (await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(31, 31),
                      ),
                    )
                    as ReadbackOutput)
                .image;
        expect(image.pixels.sublist(1920, 1924), [0, 0, 0, 255]);
      }
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');
  test(
    'native glass preserves Fresnel, tint, absorption, maps, instance scale and live capture',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(1, 1, 1);
        final geometry = PlaneGeometry(width: 4, height: 4);
        final glass = scene.add(
          Mesh(geometry, PhysicalMaterial(transmission: 1, roughness: 0)),
        );
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
        Future<List<int>> draw({String mode = 'hdr'}) async {
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(31, 31),
                      colorPipeline: mode == 'sdr'
                          ? null
                          : ColorPipeline(
                              toneMapping: ToneMapping.linear,
                              sampleCount: mode == 'msaa' ? 4 : 1,
                            ),
                      temporalAA: mode == 'taa' ? TemporalAAOptions() : null,
                    ),
                  )
                  as ReadbackOutput;
          return output.image.pixels.sublist(1920, 1924);
        }

        void pixel(List<int> actual, List<double> expected) {
          for (var c = 0; c < 3; c++) {
            expect(
              actual[c],
              closeTo(srgb(expected[c]), 2),
              reason: '$actual vs $expected',
            );
          }
          expect(actual[3], 255);
        }

        for (final mode in ['sdr', 'hdr', 'msaa', 'taa']) {
          pixel(await draw(mode: mode), [.96, .96, .96]);
        }
        glass.material = PhysicalMaterial(
          transmission: 1,
          metallic: 1,
          roughness: 0,
          metallicRoughnessMap: dataMap(255, 255),
        );
        pixel(await draw(), [.96, .96, .96]);
        glass.material = PhysicalMaterial(
          transmission: 1,
          ior: 1,
          roughness: 0,
          baseColor: const Color3(.5, .8, 1),
          thickness: 1,
          attenuationColor: const Color3(.5, .25, 1),
          attenuationDistance: 1,
        );
        pixel(await draw(), [.25, .2, 1]);
        glass.scale = const Vec3(1, 1, 2);
        pixel(await draw(), [.125, .05, 1]);
        glass.scale = const Vec3(1, 1, 1);
        glass.material = (glass.material as PhysicalMaterial).copyWith(
          transmissionMap: dataMap(128, 128),
          thicknessMap: dataMap(128, 128),
        );
        pixel(await draw(), [
          .5 * math.pow(.5, 128 / 255) * 128 / 255,
          .8 * math.pow(.25, 128 / 255) * 128 / 255,
          128 / 255,
        ]);
        glass.material = PhysicalMaterial(
          transmission: 1,
          ior: 1,
          roughness: 0,
        );
        scene.background = const Color3(.2, .4, .6);
        pixel(await draw(mode: 'taa'), [.2, .4, .6]);
        scene.background = const Color3(.6, .2, .1);
        pixel(await draw(mode: 'taa'), [.6, .2, .1]);
        expect((await backend.transmissionStats()).residentBytes, 31 * 31 * 12);
        scene.remove(glass);
        final instances = scene.add(
          InstancedMesh(
            geometry,
            PhysicalMaterial(
              transmission: 1,
              ior: 1,
              roughness: 0,
              thickness: 1,
              attenuationColor: const Color3(.5, .5, .5),
              attenuationDistance: 1,
            ),
            count: 1,
          ),
        );
        instances.setTransform(
          0,
          Mat4.compose(Vec3.zero, Quat.identity, const Vec3(1, 1, 2)),
        );
        pixel(await draw(), [.15, .05, .025]);
        scene.remove(instances);
        await draw();
        expect((await backend.transmissionStats()).residentBytes, 0);
        expect((await backend.resourceStats()).residentBytes, 0);
      } on SceneException catch (error) {
        fail(error.issue.cause.toString());
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'excess physical samplers reject before upload and allow a corrected frame',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene();
        final mesh = scene.add(Mesh(PlaneGeometry(), PhysicalMaterial()));
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
        Future<FrameOutput> draw() => backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(31, 31),
          ),
        );
        await draw();
        final before = await backend.resourceStats();
        final image = dataMap(128, 128).image;
        final maps = List.generate(
          10,
          (i) => TextureMap(
            image: image,
            sampler: SamplerDescriptor(
              wrapU: TextureWrap.values[i % 3],
              wrapV: TextureWrap.values[(i ~/ 3) % 3],
              minFilter: i == 9 ? TextureFilter.nearest : TextureFilter.linear,
            ),
          ),
        );
        mesh.material = PhysicalMaterial(
          clearcoatMap: maps[0],
          clearcoatRoughnessMap: maps[1],
          clearcoatNormalMap: maps[2],
          sheenColorMap: maps[3],
          sheenRoughnessMap: maps[4],
          specularIntensityMap: maps[5],
          specularColorMap: maps[6],
          anisotropyMap: maps[7],
          transmissionMap: maps[8],
          thicknessMap: maps[9],
        );
        await expectLater(draw(), throwsA(isA<SceneException>()));
        expect(
          (await backend.resourceStats()).residentBytes,
          before.residentBytes,
        );
        mesh.material = PhysicalMaterial();
        expect((await draw()).stats.uploadedBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'transmission retains reflected light and composes with transparent backgrounds',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final glass = scene.add(
          Mesh(
            PlaneGeometry(width: 4, height: 4),
            PhysicalMaterial(transmission: 1, roughness: 1),
          ),
        );
        scene.add(DirectionalLight(intensity: 3));
        final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
        Future<List<int>> draw() async =>
            (await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: camera,
                        size: PhysicalSize(31, 31),
                      ),
                    )
                    as ReadbackOutput)
                .image
                .pixels
                .sublist(1920, 1924);
        final reflection = await draw();
        glass.material = PhysicalMaterial(
          baseColor: const Color3(0, 0, 0),
          roughness: 1,
        );
        expect(await draw(), reflection);
        scene.backgroundOpacity = 0;
        glass.material = PhysicalMaterial(
          transmission: 1,
          ior: 1,
          roughness: 1,
        );
        expect(await draw(), [0, 0, 0, 0]);
        glass.material = PhysicalMaterial(transmission: 1, roughness: 1);
        final coverage = await draw();
        expect(coverage[3], closeTo(10, 1));
        expect(coverage[0], greaterThan(0));
      } on SceneException catch (error) {
        fail(error.issue.cause.toString());
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  for (final strategy in DepthStrategy.values) {
    test(
      '$strategy capture refracts behind glass, blurs rough glass and rejects foreground depth',
      () async {
        final backend = await NativeBackend.create();
        try {
          final scene = Scene()..background = const Color3(0, 0, 0);
          final background = scene.add(
            Mesh(
              PlaneGeometry(width: 8, height: 8),
              UnlitMaterial(color: const Color3(1, 0, 0)),
            )..position = const Vec3(0, 0, -1),
          );
          scene.add(
            Mesh(
              PlaneGeometry(width: 4, height: 8),
              UnlitMaterial(color: const Color3(0, 0, 1)),
            )..position = const Vec3(2, 0, -.9),
          );
          final plane = PlaneGeometry(width: 4, height: 4);
          final normal = const Vec3(-.8, 0, 1).normalized();
          final geometry = BufferGeometry.fromAttributes(
            attributes: {
              ...plane.attributes,
              VertexSemantic.normal: VertexAttribute(
                Float32List.fromList([
                  for (var i = 0; i < plane.vertexCount; i++) ...normal.storage,
                ]),
                format: VertexFormat.float32x3,
              ),
            },
            indices: plane.indices,
          );
          final glass = scene.add(
            Mesh(
              geometry,
              PhysicalMaterial(transmission: 1, ior: 1.5, roughness: 0),
            ),
          );
          final camera = PerspectiveCamera(
            position: const Vec3(0, 0, 3),
            depthStrategy: strategy,
          );
          Future<Uint8List> draw() async =>
              (await backend.render(
                        FrameSubmission.capture(
                          scene: scene,
                          camera: camera,
                          size: PhysicalSize(63, 63),
                          colorPipeline: ColorPipeline(
                            toneMapping: ToneMapping.linear,
                          ),
                        ),
                      )
                      as ReadbackOutput)
                  .image
                  .pixels;
          final thin = await draw();
          glass.material = (glass.material as PhysicalMaterial).copyWith(
            thickness: 1,
          );
          final refracted = await draw();
          final p = (31 * 63 + 29) * 4;
          expect(thin[p], greaterThan(200));
          expect(thin[p + 2], lessThan(20));
          expect(refracted[p + 2], greaterThan(200));
          expect(refracted[p], lessThan(20));
          glass.material = (glass.material as PhysicalMaterial).copyWith(
            thickness: 0,
            roughness: 1,
          );
          final rough = await draw();
          expect(rough[p + 2], greaterThan(50));
          expect(rough[p], greaterThan(50));
          glass.material = (glass.material as PhysicalMaterial).copyWith(
            thickness: 1,
            roughness: 0,
          );
          final foreground = scene.add(
            Mesh(
              PlaneGeometry(width: .25, height: 4),
              UnlitMaterial(color: const Color3(0, 1, 0)),
            )..position = const Vec3(.3, 0, 1),
          );
          final rejected = await draw();
          expect(rejected[p + 1], lessThan(10));
          scene.remove(foreground);
          background.material = UnlitMaterial(color: const Color3(1, 1, 0));
          glass.material = (glass.material as PhysicalMaterial).copyWith(
            thickness: 0,
          );
          expect((await draw())[p + 1], greaterThan(200));
        } on SceneException catch (error) {
          fail(error.issue.cause.toString());
        } finally {
          await backend.close();
        }
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    );
  }
}
