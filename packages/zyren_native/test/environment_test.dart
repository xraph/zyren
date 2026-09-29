import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';
import 'support/environment_checks.dart';

void main() {
  test(
    'directional environment matches analytic convolution and PBR rotation',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyEnvironment(backend);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'lighting plugin replaces at frame boundaries and survives failed images',
    () async {
      final backend = await NativeBackend.create();
      final view = backend.createView();
      final plugin = EnvironmentLighting(
        image: constantEnvironment(2, 4, 8),
        intensity: .125,
        quality: smallEnvironment,
      );
      final scene = Scene()..background = const Color3(0, 0, 0);
      scene.add(
        Mesh(
          PlaneGeometry(width: 4, height: 4),
          StandardMaterial(
            baseColor: const Color3(1, 1, 1),
            metallic: 1,
            roughness: 0,
          ),
        ),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(position: const Vec3(0, 0, 2)),
        backendFactory: () async => view,
        plugins: [plugin],
      );
      Future<ReadbackOutput> draw() async =>
          await engine.renderFrame(
                elapsed: Duration.zero,
                width: 15,
                height: 15,
                colorPipeline: ColorPipeline(toneMapping: ToneMapping.linear),
              )
              as ReadbackOutput;
      try {
        expectPixel(await draw(), [137, 188, 255, 255]);
        final original = plugin.map!;
        await expectLater(
          plugin.setImage(
            HdrImageData(
              pixels: Float32List.fromList([1, 1, 1, 1]),
              size: PhysicalSize(1, 1),
            ),
          ),
          throwsArgumentError,
        );
        expect(plugin.map, same(original));
        expect(original.isClosed, isFalse);
        expectPixel(await draw(), [137, 188, 255, 255]);
        plugin.intensity = .0625;
        final scaled = await draw();
        expectPixel(scaled, [99, 137, 188, 255]);
        expect(scaled.stats.uploadedBytes, 0);
        expect(plugin.map, same(original));
        await plugin.setImage(constantEnvironment(4, 2, 0));
        expect(plugin.map, same(original));
        expect(original.isClosed, isFalse);
        expectPixel(await draw(), [137, 99, 0, 255]);
        expect(original.isClosed, isTrue);
        final replaced = plugin.map!;
        await plugin.setImage(null);
        expectPixel(await draw(), [0, 0, 0, 255]);
        expect(replaced.isClosed, isTrue);
        expect(plugin.map, isNull);
        final pending = plugin.setImage(constantEnvironment(1, 1, 1));
        final cancelled = expectLater(pending, throwsStateError);
        await engine.dispose();
        await cancelled;
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await engine.dispose();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'prepared environment reaches PBR frames without inventing default light',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      try {
        final map = await EnvironmentMap.fromEquirectangular(
          HdrImageData(
            pixels: Float32List.fromList([2, 4, 8, 1, 2, 4, 8, 1]),
            size: PhysicalSize(2, 1),
          ),
          resources: resources,
          quality: const EnvironmentQuality(
            specularWidth: 16,
            diffuseWidth: 16,
            brdfSize: 16,
            samples: 64,
          ),
        );
        final scene = Scene()..background = const Color3(0, 0, 0);
        scene.add(
          Mesh(
            BoxGeometry(),
            StandardMaterial(
              baseColor: const Color3(1, 1, 1),
              metallic: 1,
              roughness: 0,
              side: MaterialSide.front,
            ),
          ),
        );
        final camera = PerspectiveCamera()..position = const Vec3(0, 0, 3);
        for (final environment in [
          Environment(map: map, intensity: .125),
          null,
        ]) {
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(15, 15),
                      colorPipeline: ColorPipeline(
                        toneMapping: ToneMapping.linear,
                      ),
                      environment: environment,
                      target: const ReadbackTarget(),
                    ),
                  )
                  as ReadbackOutput;
          final pixel = output.image.pixels.sublist(448, 452);
          final expected = environment == null
              ? [0, 0, 0, 255]
              : [137, 188, 255, 255];
          for (var i = 0; i < 4; i++) {
            expect(pixel[i], closeTo(expected[i], 2), reason: '$pixel');
          }
        }
      } finally {
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'environment preparation preserves constant HDR radiance and releases resources',
    () async {
      final backend = await NativeBackend.create();
      final resources = backend.createResourceScope();
      try {
        final image = HdrImageData(
          pixels: Float32List.fromList([2, 4, 8, 1, 2, 4, 8, 1]),
          size: PhysicalSize(2, 1),
        );
        final environment = await EnvironmentMap.fromEquirectangular(
          image,
          resources: resources,
          quality: const EnvironmentQuality(
            specularWidth: 16,
            diffuseWidth: 16,
            brdfSize: 16,
            samples: 64,
          ),
        );
        final inspection = resources.createChild();
        try {
          for (final texture in [environment.diffuse, environment.specular]) {
            final retained = await inspection.retain(texture);
            final descriptor = texture.descriptor as TextureDescriptor;
            for (var mip = 0; mip < descriptor.mipLevels; mip++) {
              final bytes = await inspection.readTexture(
                retained,
                mipLevel: mip,
              );
              final values = ByteData.sublistView(bytes);
              for (var i = 0; i < bytes.length; i += 8) {
                for (final (channel, expected) in [
                  (0, 0x4000),
                  (1, 0x4400),
                  (2, 0x4800),
                  (3, 0x3c00),
                ]) {
                  expect(
                    values.getUint16(i + channel * 2, Endian.little),
                    closeTo(expected, 1),
                    reason: 'one binary16 ULP',
                  );
                }
              }
            }
          }
          final brdf = await inspection.retain(environment.brdf);
          final values = ByteData.sublistView(
            await inspection.readTexture(brdf),
          );
          for (var i = 0; i < values.lengthInBytes; i += 8) {
            for (final offset in [0, 2]) {
              final bits = values.getUint16(i + offset, Endian.little);
              expect(
                bits,
                lessThanOrEqualTo(0x3c00),
                reason: 'finite BRDF factor in [0, 1]',
              );
            }
          }
        } finally {
          await inspection.close();
        }
        await environment.close();
        expect(environment.isClosed, isTrue);
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await resources.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
