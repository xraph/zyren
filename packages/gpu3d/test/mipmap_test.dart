import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
  test('generated chains reserve every level but transfer only the base', () {
    final image = TextureImage.rgba(
      width: 5,
      height: 3,
      pixels: Uint8List(60),
      generateMipmaps: true,
      mipmapAlphaFilter: MipmapAlphaFilter.weighted,
    );
    expect(image.descriptor.mipLevels, 3);
    expect(image.descriptor.byteLength, 72);
    expect(image.levels.length, 1);
    expect(image.generatesMipmaps, isTrue);
    final frame = FrameSubmission.capture(
      scene: Scene()
        ..background = const Color3(0, 0, 0)
        ..add(
          Mesh(
            PlaneGeometry(),
            UnlitMaterial(colorMap: TextureMap(image: image)),
          ),
        ),
      camera: PerspectiveCamera(),
      size: PhysicalSize(31, 31),
    );
    final packet = ScenePacketEncoder(viewId: 1).encode(frame);
    expect(packet.uploadedBytes, 244); // 184 geometry + 60 base image.
    expect(ByteData.sublistView(packet.bytes).getUint32(4, Endian.little), 14);
  });
  test(
    'generation rejects supplied chains and budgets all levels before copying',
    () {
      expect(
        () => TextureImage.rgba(
          width: 2,
          height: 2,
          pixels: Uint8List(16),
          mipmaps: [Uint8List(4)],
          generateMipmaps: true,
        ),
        throwsArgumentError,
      );
      expect(
        () => TextureImage.rgba(
          width: 4096,
          height: 4096,
          pixels: Uint8List(0),
          generateMipmaps: true,
        ),
        throwsArgumentError,
      );
      final image = TextureImage.fromImage(
        ImageData(pixels: Uint8List(16), size: PhysicalSize(2, 2)),
        generateMipmaps: true,
      );
      expect(image.descriptor.byteLength, 20);
      expect(image.levels.single.length, 16);
    },
  );
}
