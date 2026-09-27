import 'dart:typed_data';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'shared native images preserve color and release the final owner',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final first = await NativeBackend.create();
      final second = first.createView();
      final image = TextureImage.rgba(
        width: 1,
        height: 1,
        pixels: Uint8List.fromList([128, 128, 128, 0]),
      );
      final mesh = Mesh(
        PlaneGeometry(),
        UnlitMaterial(colorMap: TextureMap(image: image)),
      );
      final scene = Scene()..add(mesh);
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(31, 31),
      );
      List<int> center(ReadbackOutput frame) => frame.image.pixels.sublist(
        (15 * 31 + 15) * 4,
        (15 * 31 + 15) * 4 + 4,
      );
      try {
        final frames = await Future.wait([
          first.render(capture()),
          second.render(capture()),
        ]);
        expect(
          frames.fold(0, (sum, frame) => sum + frame.stats.uploadedBytes),
          188,
        );
        expect(center(frames.first as ReadbackOutput), [128, 128, 128, 255]);
        mesh.visible = false;
        await second.render(capture());
        await first.close();
        expect((await second.resourceStats()).residentBytes, 188);
        mesh.visible = true;
        final restored = await second.render(capture()) as ReadbackOutput;
        expect(restored.stats.uploadedBytes, 0);
        expect(center(restored), [128, 128, 128, 255]);
        mesh.material = UnlitMaterial(
          colorMap: TextureMap(
            image: TextureImage.rgba(
              width: 1,
              height: 1,
              format: TextureFormat.rgba8Unorm,
              pixels: Uint8List.fromList([128, 128, 128, 255]),
            ),
          ),
        );
        final linear = await second.render(capture()) as ReadbackOutput;
        expect(center(linear)[0], closeTo(188, 1));
        expect(linear.stats.uploadedBytes, 4);
        expect((await second.resourceStats()).residentBytes, 188);
        scene.remove(mesh);
        await second.render(capture());
        expect((await second.resourceStats()).residentBytes, 0);
      } finally {
        await first.close();
        await second.close();
      }
    },
  );
  testWidgets(
    'two views share native geometry through hide, close and restore',
    (tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      final first = await NativeBackend.create();
      final second = first.createView();
      final mesh = Mesh(
        BoxGeometry(),
        UnlitMaterial(color: const Color3(1, 0, 0)),
      );
      final scene = Scene()..add(mesh);
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(31, 31),
      );
      try {
        final frames = await Future.wait([
          first.render(capture()),
          second.render(capture()),
        ]);
        expect(
          frames.fold(0, (sum, frame) => sum + frame.stats.uploadedBytes),
          720,
        );
        mesh.position = const Vec3(.1, 0, 0);
        expect((await second.render(capture())).stats.uploadedBytes, 0);
        mesh.visible = false;
        await second.render(capture());
        await first.close();
        expect((await second.resourceStats()).residentBytes, 720);
        mesh.visible = true;
        final restored = await second.render(capture()) as ReadbackOutput;
        final center = (15 * 31 + 15) * 4;
        expect(restored.image.pixels.sublist(center, center + 4), [
          255,
          0,
          0,
          255,
        ]);
        expect(restored.stats.uploadedBytes, 0);
        scene.remove(mesh);
        await second.render(capture());
        expect((await second.resourceStats()).residentBytes, 0);
      } finally {
        await first.close();
        await second.close();
      }
    },
  );
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
