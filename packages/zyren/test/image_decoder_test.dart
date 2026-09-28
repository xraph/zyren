import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test('decoded rows become independent texture pixels without padding', () {
    final pixels = Uint8List.fromList([
      255,
      0,
      0,
      128,
      99,
      99,
      99,
      99,
      0,
      0,
      255,
      255,
      99,
      99,
      99,
      99,
    ]);
    final image = ImageData(
      pixels: pixels,
      size: PhysicalSize(1, 2),
      rowStride: 8,
      colorSpace: ColorSpace.linear,
    );
    final texture = TextureImage.fromImage(image);
    pixels[0] = 0;
    expect(texture.levels.single, [255, 0, 0, 128, 0, 0, 255, 255]);
    expect(texture.descriptor.format, TextureFormat.rgba8Unorm);
    expect(
      () => TextureImage.fromImage(
        ImageData(
          pixels: Uint8List(4),
          size: PhysicalSize(1, 1),
          alphaMode: AlphaMode.premultiplied,
        ),
      ),
      throwsUnsupportedError,
    );
  });
  test('decode limits reject invalid options and oversized encoded input', () {
    expect(
      () => const ImageDecodeLimits(maxDimension: 0).validate(),
      throwsArgumentError,
    );
    expect(
      () =>
          const ImageDecodeLimits(maxDecodedBytes: 65 * 1024 * 1024).validate(),
      throwsArgumentError,
    );
    expect(
      () => const ImageDecodeLimits(
        maxEncodedBytes: 4,
      ).validateInput(Uint8List(5)),
      throwsA(
        isA<ImageDecodeException>().having(
          (e) => e.code,
          'code',
          ImageDecodeError.limitExceeded,
        ),
      ),
    );
  });
}
