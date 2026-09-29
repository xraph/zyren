import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  test('decoder selection requires enabled linear and sRGB storage', () {
    TextureTranscodeTarget choose(Set<TextureFormat> formats) =>
        NativeTextureDecoder.forDevice(
          DeviceCapabilities(
            name: 'fixture',
            features: {},
            textureFormats: formats,
            limits: DeviceLimits(
              maxTextureDimension2D: 4096,
              maxGeometryBytes: 1024,
            ),
          ),
        ).target;
    expect(choose({}), TextureTranscodeTarget.rgba8);
    expect(choose({TextureFormat.astc4x4Unorm}), TextureTranscodeTarget.rgba8);
    expect(
      choose({TextureFormat.etc2Rgba8Unorm, TextureFormat.etc2Rgba8UnormSrgb}),
      TextureTranscodeTarget.etc2Rgba8,
    );
    expect(
      choose({
        TextureFormat.bc7RgbaUnorm,
        TextureFormat.bc7RgbaUnormSrgb,
        TextureFormat.etc2Rgba8Unorm,
        TextureFormat.etc2Rgba8UnormSrgb,
      }),
      TextureTranscodeTarget.bc7,
    );
    expect(
      choose(TextureFormat.values.toSet()),
      TextureTranscodeTarget.astc4x4,
    );
  });
  test(
    'Basis targets retain blocks and authored mip tails without a device',
    () async {
      for (final kind in ['etc1s', 'uastc', 'zstd']) {
        final bytes = await File(
          '../../test_assets/compression/colors-$kind.ktx2',
        ).readAsBytes();
        for (final target in TextureTranscodeTarget.values.skip(1)) {
          final decoded = await NativeTextureDecoder(target: target).decode(
            bytes,
            encoding: TextureEncoding.ktx2Basis,
            limits: const ImageDecodeLimits(maxDecodedBytes: 112),
          );
          expect(decoded.levels.map((l) => l.length), [64, 16, 16, 16]);
          expect(decoded.descriptor.byteLength, 112);
          expect(decoded.descriptor.format.isCompressed, true);
          expect(decoded.descriptor.format.isSrgb, true);
        }
      }
    },
  );
  test(
    'native compressed formats round trip blocks and render all mip tails',
    () async {
      final backend = await NativeBackend.create();
      try {
        final formats = backend.capabilities.textureFormats;
        expect(
          formats,
          containsAll([
            TextureFormat.rgba8Unorm,
            TextureFormat.rgba8UnormSrgb,
            TextureFormat.rgba16Float,
          ]),
        );
        final bytes = await File(
          '../../test_assets/compression/colors-uastc.ktx2',
        ).readAsBytes();
        final negotiated = NativeTextureDecoder.forDevice(backend.capabilities);
        final chosen = await negotiated.decode(
          bytes,
          encoding: TextureEncoding.ktx2Basis,
        );
        expect(formats, contains(chosen.descriptor.format));
        final scene = Scene()..background = const Color3(0, 0, 0);
        final geometry = PlaneGeometry(width: 2, height: 2);
        final mesh = scene.add(Mesh(geometry, UnlitMaterial()));
        final camera = OrthographicCamera(
          verticalSize: 2,
          position: const Vec3(0, 0, 3),
        );
        Future<ImageData> draw(TextureImageData texture, int size) async {
          mesh.material = UnlitMaterial(
            colorMap: TextureMap(
              image: TextureImage.fromData(texture),
              sampler: const SamplerDescriptor(
                minFilter: TextureFilter.nearest,
                magFilter: TextureFilter.nearest,
                mipFilter: TextureFilter.nearest,
              ),
            ),
            alphaMode: MaterialAlphaMode.blend,
          );
          return (await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: camera,
                      size: PhysicalSize(size, size),
                    ),
                  )
                  as ReadbackOutput)
              .image;
        }

        final rgba = await const NativeTextureDecoder().decode(
          bytes,
          encoding: TextureEncoding.ktx2Basis,
        );
        final references = [
          for (final size in [8, 4, 2, 1]) await draw(rgba, size),
        ];
        for (final target in TextureTranscodeTarget.values.skip(1)) {
          final data = await NativeTextureDecoder(
            target: target,
          ).decode(bytes, encoding: TextureEncoding.ktx2Basis);
          final scope = backend.createResourceScope();
          try {
            final descriptor = TextureDescriptor(
              width: 8,
              height: 8,
              mipLevels: 4,
              format: data.descriptor.format,
              usage: {
                TextureUsage.sampled,
                TextureUsage.copySource,
                TextureUsage.copyDestination,
              },
            );
            if (!formats.contains(descriptor.format)) {
              await expectLater(
                scope.createTexture(descriptor),
                throwsA(isA<ResourceException>()),
              );
              continue;
            }
            final before = await backend.resourceStats();
            final texture = await scope.createTexture(descriptor);
            for (var mip = 0; mip < 4; mip++) {
              await scope.writeTexture(
                texture,
                data.levels[mip],
                mipLevel: mip,
              );
              expect(
                await scope.readTexture(texture, mipLevel: mip),
                data.levels[mip],
              );
            }
            final after = await backend.resourceStats();
            expect(after.residentBytes - before.residentBytes, 112);
            expect(after.uploadedBytes - before.uploadedBytes, 112);
            for (var mip = 0; mip < 4; mip++) {
              final actual = await draw(data, 8 >> mip);
              final expected = references[mip];
              // ETC2 has a small color palette per block. The authored 2x2
              // mip puts four saturated colors into one block; allow its codec
              // error while checking exact raw blocks separately above.
              final tolerance = target == TextureTranscodeTarget.etc2Rgba8
                  ? [4, 40, 90, 4][mip]
                  : 12;
              for (var i = 0; i < actual.pixels.length; i++) {
                expect(
                  actual.pixels[i],
                  closeTo(expected.pixels[i], i % 4 == 3 ? 2 : tolerance),
                  reason: '$target mip$mip channel$i',
                );
              }
            }
            final stable = await backend.resourceStats();
            await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: camera,
                size: PhysicalSize(1, 1),
              ),
            );
            expect(
              (await backend.resourceStats()).uploadedBytes,
              stable.uploadedBytes,
            );
          } finally {
            await scope.close();
          }
        }
        scene.remove(mesh);
        await backend.render(
          FrameSubmission.capture(
            scene: scene,
            camera: camera,
            size: PhysicalSize(8, 8),
          ),
        );
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
