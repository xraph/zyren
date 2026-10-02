import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

void main() {
  test(
    'floating volume mips shrink all axes and account for channel bytes',
    () {
      final volume = TextureDescriptor(
        width: 7,
        height: 5,
        depth: 3,
        dimension: TextureDimension.d3,
        mipLevels: 3,
        format: TextureFormat.rgba16Float,
        usage: {TextureUsage.storage, TextureUsage.sampled},
      );
      expect(volume.mipByteLength(0), 7 * 5 * 3 * 8);
      expect(volume.mipByteLength(1), 3 * 2 * 1 * 8);
      expect(volume.mipByteLength(2), 8);
      expect(volume.byteLength, 896);
      expect(
        TextureDescriptor(
          width: 2,
          height: 2,
          format: TextureFormat.rgba32Float,
        ).byteLength,
        64,
      );
      expect(
        TextureDescriptor(
          width: 2,
          height: 2,
          format: TextureFormat.r32Float,
        ).byteLength,
        16,
      );
    },
  );

  test(
    'volume descriptors enforce dimension, attachment and memory limits',
    () {
      expect(
        () => TextureDescriptor(width: 2, height: 2, depth: 2),
        throwsArgumentError,
      );
      expect(
        () => TextureDescriptor(
          width: 2,
          height: 2,
          depth: 0,
          dimension: TextureDimension.d3,
        ),
        throwsArgumentError,
      );
      expect(
        () => TextureDescriptor(
          width: 257,
          height: 2,
          depth: 2,
          dimension: TextureDimension.d3,
        ),
        throwsArgumentError,
      );
      expect(
        () => TextureDescriptor(
          width: 256,
          height: 256,
          depth: 256,
          dimension: TextureDimension.d3,
          format: TextureFormat.rgba16Float,
        ),
        throwsArgumentError,
      );
      expect(
        () => TextureDescriptor(
          width: 2,
          height: 2,
          depth: 2,
          dimension: TextureDimension.d3,
          usage: {TextureUsage.renderAttachment},
        ),
        throwsArgumentError,
      );
      expect(
        () => TextureDescriptor(
          width: 2,
          height: 2,
          format: TextureFormat.rgba8UnormSrgb,
          usage: {TextureUsage.storage},
        ),
        throwsArgumentError,
      );
    },
  );

  test('RGBA image constructors reject floating formats explicitly', () {
    expect(
      () => TextureImage.rgba(
        width: 1,
        height: 1,
        format: TextureFormat.rgba16Float,
        pixels: Uint8List(8),
      ),
      throwsArgumentError,
    );
  });
}
