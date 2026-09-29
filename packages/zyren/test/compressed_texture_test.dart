import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test('compressed mip tails occupy whole blocks and own their bytes', () {
    for (final format in TextureFormat.values.where((f) => f.isCompressed)) {
      final descriptor = TextureDescriptor(
        width: 12,
        height: 8,
        mipLevels: 4,
        format: format,
      );
      expect(List.generate(4, descriptor.mipByteLength), [96, 32, 16, 16]);
      expect(descriptor.byteLength, 160);
      final source = Uint8List(96);
      final data = TextureImageData.compressed(
        width: 12,
        height: 8,
        format: format,
        blocks: source,
        mipmaps: [Uint8List(32), Uint8List(16), Uint8List(16)],
      );
      source[0] = 255;
      expect(data.levels.first[0], 0);
      expect(() => data.levels.first[0] = 3, throwsUnsupportedError);
      expect(data.generatesMipmaps, false);
      expect(
        data.descriptor.format.withSrgb(!format.isSrgb).isSrgb,
        !format.isSrgb,
      );
      expect(
        () => TextureImageData.rgba(
          width: 12,
          height: 8,
          pixels: source,
          format: format,
        ),
        throwsArgumentError,
      );
      expect(
        () => TextureDescriptor(width: 5, height: 4, format: format),
        throwsArgumentError,
      );
      expect(
        () => TextureDescriptor(
          width: 4,
          height: 4,
          format: format,
          usage: {TextureUsage.sampled, TextureUsage.renderAttachment},
        ),
        throwsArgumentError,
      );
    }
  });
  test('linear compressed maps work as physical data maps', () {
    final image = TextureImage.fromData(
      TextureImageData.compressed(
        width: 4,
        height: 4,
        format: TextureFormat.bc7RgbaUnorm,
        blocks: Uint8List(16),
      ),
    );
    expect(
      PhysicalMaterial(
        iridescenceMap: TextureMap(image: image),
      ).iridescenceMap!.image,
      same(image),
    );
    final srgb = TextureImage.fromData(
      TextureImageData.compressed(
        width: 4,
        height: 4,
        format: TextureFormat.bc7RgbaUnormSrgb,
        blocks: Uint8List(16),
      ),
    );
    expect(
      () => PhysicalMaterial(iridescenceMap: TextureMap(image: srgb)),
      throwsArgumentError,
    );
  });
}
