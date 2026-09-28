import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:gpu3d_native/src/bindings.dart' as native;
import 'package:test/test.dart';
import 'support/hdr_asset_checks.dart';

void main() {
  const decoder = NativeHdrImageDecoder();
  test('CPU HDR decoding snapshots input and creates no renderer', () async {
    final renderers = native.liveRendererCount();
    final bytes = hdrFixture();
    final pending = decoder.decode(bytes);
    bytes.fillRange(0, bytes.length, 0);
    final image = await pending;
    expect([image.size.width, image.size.height], [2, 2]);
    expect(image.pixels.take(4), [.25, 2, 4, 1]);
    expect(() => image.pixels[0] = 0, throwsUnsupportedError);
    expect(native.liveRendererCount(), renderers);
  });
  test('HDR failures keep typed errors across the isolate boundary', () async {
    final good = hdrFixture();
    for (final (bytes, limits, code) in [
      (Uint8List(0), const ImageDecodeLimits(), ImageDecodeError.invalidData),
      (
        Uint8List.fromList([71, 73, 70, 10]),
        const ImageDecodeLimits(),
        ImageDecodeError.unsupportedFormat,
      ),
      (
        Uint8List.sublistView(good, 0, good.length - 1),
        const ImageDecodeLimits(),
        ImageDecodeError.invalidData,
      ),
      (
        good,
        const ImageDecodeLimits(maxDecodedBytes: 63),
        ImageDecodeError.limitExceeded,
      ),
      (
        good,
        const ImageDecodeLimits(maxDimension: 1),
        ImageDecodeError.limitExceeded,
      ),
      (
        good,
        const ImageDecodeLimits(maxWorkingBytes: 1),
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
    expect((await decoder.decode(good)).pixels[1], 2);
  });
  test(
    'HDR isolate admission rejects a third decode and then recovers',
    () async {
      final first = decoder.decode(hdrFixture());
      final second = decoder.decode(hdrFixture());
      await expectLater(
        decoder.decode(hdrFixture()),
        throwsA(
          isA<ImageDecodeException>().having(
            (e) => e.code,
            'code',
            ImageDecodeError.busy,
          ),
        ),
      );
      expect(await Future.wait([first, second]), hasLength(2));
      expect((await decoder.decode(hdrFixture())).pixels[2], 4);
    },
  );
  test('HDR file loading uses the scoped CPU asset services', () async {
    final directory = await Directory.systemTemp.createTemp('gpu3d-hdr-');
    final scope = AssetScope(
      services: const AssetServices(
        resolver: NativeSourceResolver(),
        hdrImageDecoder: NativeHdrImageDecoder(),
      ),
    );
    try {
      final file = await File(
        '${directory.path}/environment.hdr',
      ).writeAsBytes(hdrFixture());
      final image = await scope
          .load(AssetRequest(uri: file.uri, loader: const HdrImageLoader()))
          .result;
      expect(image.pixels[1], 2);
      scope.release(image);
      expect(image.toRgba16Float(), hasLength(32));
    } finally {
      await scope.close();
      await directory.delete(recursive: true);
    }
  });
  test(
    'HDR decoding, float upload, mip generation and compute stay linear',
    () async {
      final backend = await NativeBackend.create();
      try {
        await verifyHdrAsset(backend);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
