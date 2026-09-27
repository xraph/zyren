import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:gpu3d_native/src/bindings.dart' as native;
import 'package:test/test.dart';

void main() {
  final decoder = NativeImageDecoder();
  Future<Uint8List> fixture(String name) =>
      File('../../test_assets/images/$name').readAsBytes();
  test(
    'CPU decoder snapshots input and preserves straight PNG pixels without a GPU',
    () async {
      final before = native.liveRendererCount();
      final bytes = await fixture('corners.png');
      final pending = decoder.decode(bytes);
      bytes.fillRange(0, bytes.length, 0);
      final image = await pending;
      expect([image.size.width, image.size.height], [2, 2]);
      expect(image.pixels, [
        255,
        0,
        0,
        128,
        0,
        255,
        0,
        255,
        0,
        0,
        255,
        0,
        255,
        255,
        255,
        255,
      ]);
      expect(image.alphaMode, AlphaMode.straight);
      expect(image.colorSpace, ColorSpace.srgb);
      expect(() => image.pixels[0] = 0, throwsUnsupportedError);
      expect(TextureImage.fromImage(image).levels.single, image.pixels);
      expect(native.liveRendererCount(), before);
    },
  );
  test('JPEG pixels and typed failures survive the isolate boundary', () async {
    final jpeg = await fixture('gray.jpg');
    final image = await decoder.decode(jpeg);
    expect([image.size.width, image.size.height], [8, 8]);
    expect(image.pixels.first, closeTo(128, 1));
    expect(image.pixels[3], 255);
    final png = await fixture('corners.png');
    for (final (bytes, limits, code) in [
      (
        Uint8List.fromList([71, 73, 70, 56, 57, 97]),
        const ImageDecodeLimits(),
        ImageDecodeError.unsupportedFormat,
      ),
      (
        Uint8List.sublistView(jpeg, 0, jpeg.length - 2),
        const ImageDecodeLimits(),
        ImageDecodeError.invalidData,
      ),
      (
        png,
        const ImageDecodeLimits(maxDimension: 1),
        ImageDecodeError.limitExceeded,
      ),
      (
        png,
        const ImageDecodeLimits(maxDecodedBytes: 15),
        ImageDecodeError.limitExceeded,
      ),
    ]) {
      await expectLater(
        decoder.decode(bytes, limits: limits),
        throwsA(
          isA<ImageDecodeException>().having((e) => e.code, 'code', code),
        ),
      );
    }
    expect((await decoder.decode(png)).pixels.first, 255);
  });
  test(
    'decoder bounds concurrent admissions and recovers after completion',
    () async {
      final bytes = await fixture('corners.png');
      final first = decoder.decode(bytes), second = decoder.decode(bytes);
      await expectLater(
        decoder.decode(bytes),
        throwsA(
          isA<ImageDecodeException>().having(
            (e) => e.code,
            'code',
            ImageDecodeError.busy,
          ),
        ),
      );
      expect(await Future.wait([first, second]), hasLength(2));
      expect((await decoder.decode(bytes)).pixels.first, 255);
    },
  );
}
