import 'dart:isolate';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test(
    'texture recipes transfer without moving resource ID allocation',
    () async {
      final before = TextureImage.rgba(
        width: 1,
        height: 1,
        pixels: Uint8List(4),
      );
      final data = await Isolate.run(
        () => TextureImageData.rgba(
          width: 2,
          height: 1,
          pixels: Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255]),
          generateMipmaps: true,
        ),
      );
      final first = TextureImage.fromData(data);
      final second = TextureImage.fromData(data);
      expect({before.id, first.id, second.id}, hasLength(3));
      expect(first.levels, same(data.levels));
      expect(first.levels, same(second.levels));
      expect(first.generatesMipmaps, isTrue);
      expect(first.descriptor.mipLevels, 2);
      expect(() => data.levels.single[0] = 0, throwsUnsupportedError);
      expect(() => data.levels.clear(), throwsUnsupportedError);
    },
  );
  test('prepared image data copies owned bytes and strips row padding', () {
    final bytes = Uint8List.fromList([
      255,
      0,
      0,
      255,
      9,
      9,
      9,
      9,
      0,
      255,
      0,
      255,
      8,
      8,
      8,
      8,
    ]);
    final data = TextureImageData.fromImage(
      ImageData(pixels: bytes, size: PhysicalSize(1, 2), rowStride: 8),
    );
    bytes[0] = 0;
    expect(data.levels.single, [255, 0, 0, 255, 0, 255, 0, 255]);
    expect(
      () => TextureImageData.rgba(width: 2, height: 1, pixels: Uint8List(4)),
      throwsArgumentError,
    );
  });
}
