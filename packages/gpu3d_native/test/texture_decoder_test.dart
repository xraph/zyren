import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:gpu3d_native/src/bindings.dart' as native;
import 'package:gpu3d_native/src/texture_packet.dart';

Matcher error(ImageDecodeError code) =>
    isA<ImageDecodeException>().having((e) => e.code, 'code', code);
void main() {
  const decoder = NativeTextureDecoder();
  test(
    'Basis CPU worker retains authored mips, alpha and snapshot ownership',
    () async {
      final before = native.liveRendererCount();
      for (final kind in ['etc1s', 'uastc', 'zstd']) {
        final bytes = await File(
          '../../test_assets/compression/colors-$kind.ktx2',
        ).readAsBytes();
        final pending = decoder.decode(
          bytes,
          encoding: TextureEncoding.ktx2Basis,
        );
        bytes.fillRange(0, bytes.length, 0);
        final texture = await pending;
        expect(texture.levels.map((l) => l.length), [256, 64, 16, 4]);
        expect(texture.descriptor.format, TextureFormat.rgba8UnormSrgb);
        expect(texture.generatesMipmaps, isFalse);
        expect(texture.levels.first[0], greaterThan(200));
        expect(texture.levels.first[27], lessThan(110));
        expect(() => texture.levels.first[0] = 1, throwsUnsupportedError);
      }
      expect(native.liveRendererCount(), before);
    },
  );
  test(
    'limits, corruption and two-call admission release native ownership',
    () async {
      final bytes = await File(
        '../../test_assets/compression/colors-zstd.ktx2',
      ).readAsBytes();
      await expectLater(
        decoder.decode(
          bytes,
          encoding: TextureEncoding.ktx2Basis,
          limits: const ImageDecodeLimits(maxDecodedBytes: 339),
        ),
        throwsA(error(ImageDecodeError.limitExceeded)),
      );
      await expectLater(
        decoder.decode(
          Uint8List.sublistView(bytes, 0, bytes.length - 1),
          encoding: TextureEncoding.ktx2Basis,
        ),
        throwsA(error(ImageDecodeError.invalidData)),
      );
      final first = decoder.decode(bytes, encoding: TextureEncoding.ktx2Basis);
      final second = decoder.decode(bytes, encoding: TextureEncoding.ktx2Basis);
      await expectLater(
        decoder.decode(bytes, encoding: TextureEncoding.ktx2Basis),
        throwsA(error(ImageDecodeError.busy)),
      );
      expect(await Future.wait([first, second]), hasLength(2));
    },
  );
  test('texture packet rejects malformed counts and lengths', () {
    for (final bytes in [
      Uint8List(0),
      Uint8List(20),
      Uint8List.fromList(List.filled(80, 255)),
    ]) {
      expect(
        () => decodeTexturePacket(bytes, const ImageDecodeLimits()),
        throwsA(error(ImageDecodeError.invalidData)),
      );
    }
  });
}
