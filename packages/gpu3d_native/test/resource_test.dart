import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'native buffer sharing, binary updates and texture mips round trip',
    () async {
      final backend = await NativeBackend.create();
      expect(backend, isA<ResourceBackend>());
      expect(
        backend.capabilities.supports(RenderFeature.scopedResources),
        isTrue,
      );
      final first = backend.createResourceScope(label: 'first view');
      final second = backend.createResourceScope(label: 'second view');
      try {
        final buffer = await first.createBuffer(
          BufferDescriptor(
            label: 'positions',
            size: 32,
            usage: {
              BufferUsage.vertex,
              BufferUsage.copySource,
              BufferUsage.copyDestination,
            },
          ),
        );
        final bytes = Uint8List.fromList(List.generate(32, (i) => i));
        await first.writeBuffer(buffer, bytes);
        expect(await first.readBuffer(buffer), bytes);
        final shared = await second.retain(buffer);
        await first.close();
        expect((await backend.resourceStats()).residentBytes, 32);
        await second.writeBuffer(
          shared,
          Uint32List.fromList([0xabcdef01]),
          offset: 12,
        );
        expect(await second.readBuffer(shared, offset: 12, length: 4), [
          1,
          239,
          205,
          171,
        ]);
        final texture = await second.createTexture(
          TextureDescriptor(
            label: 'odd-width atlas',
            width: 3,
            height: 5,
            mipLevels: 3,
            usage: {
              TextureUsage.sampled,
              TextureUsage.copyDestination,
              TextureUsage.copySource,
            },
          ),
        );
        for (var mip = 0; mip < 3; mip++) {
          final length = (texture.descriptor as TextureDescriptor)
              .mipByteLength(mip);
          final pixels = Uint8List.fromList(
            List.generate(length, (i) => (i * 17 + mip) % 256),
          );
          await second.writeTexture(texture, pixels, mipLevel: mip);
          expect(await second.readTexture(texture, mipLevel: mip), pixels);
        }
        final stats = await backend.resourceStats();
        expect(stats.liveAllocations, 2);
        expect(stats.residentBytes, 32 + 72);
        expect(stats.uploadedBytes, 32 + 4 + 72);
        final rendered =
            await backend.render(
                  FrameSubmission.capture(
                    scene: Scene()
                      ..add(
                        Mesh(
                          BoxGeometry(),
                          UnlitMaterial(color: const Color3(1, 0, 0)),
                        ),
                      ),
                    camera: PerspectiveCamera(),
                    size: PhysicalSize(31, 31),
                  ),
                )
                as ReadbackOutput;
        final center = (15 * 31 + 15) * 4;
        expect(rendered.image.pixels.sublist(center, center + 4), [
          255,
          0,
          0,
          255,
        ]);
        expect(
          (await backend.resourceStats()).uploadedBytes,
          stats.uploadedBytes + 720,
        );
        await second.close();
        expect((await backend.resourceStats()).residentBytes, 720);
      } on SceneException catch (error) {
        fail('${error.issue}: ${error.issue.cause}');
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'backend close drains pending resource work and closes all scopes',
    () async {
      final backend = await NativeBackend.create();
      final scope = backend.createResourceScope();
      final sibling = backend.createResourceScope();
      final pending = scope.createBuffer(
        BufferDescriptor(size: 16, usage: {BufferUsage.copyDestination}),
      );
      final rejected = expectLater(pending, throwsStateError);
      final closing = backend.close();
      expect(sibling.isClosed, isTrue);
      await closing;
      await rejected;
      expect(scope.isClosed, isTrue);
      expect(() => backend.createResourceScope(), throwsStateError);
      await backend.close();
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
