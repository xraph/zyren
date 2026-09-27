import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native device retains shared buffers and transfers texture mips',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final backend = await NativeBackend.create();
      final first = backend.createResourceScope(label: 'first');
      final second = backend.createResourceScope(label: 'second');
      try {
        final buffer = await first.createBuffer(
          BufferDescriptor(
            size: 32,
            usage: {
              BufferUsage.vertex,
              BufferUsage.copySource,
              BufferUsage.copyDestination,
            },
          ),
        );
        final input = Uint8List.fromList(List.generate(32, (i) => i * 7));
        await first.writeBuffer(buffer, input);
        final shared = await second.retain(buffer);
        await first.close();
        expect(await second.readBuffer(shared), input);
        final texture = await second.createTexture(
          TextureDescriptor(
            label: '3 by 5 atlas',
            width: 3,
            height: 5,
            mipLevels: 3,
            usage: {
              TextureUsage.sampled,
              TextureUsage.copySource,
              TextureUsage.copyDestination,
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
        expect((await backend.resourceStats()).residentBytes, 104);
        await second.close();
        final stats = await backend.resourceStats();
        expect(stats.residentBytes, 0);
        expect(stats.liveAllocations, 0);
        expect(stats.uploadedBytes, 104);
      } finally {
        await backend.close();
      }
    },
  );
}
