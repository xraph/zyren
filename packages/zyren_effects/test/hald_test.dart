import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_effects/zyren_effects.dart';

void main() {
  test(
    'Hald preserves source voxel order, strips row padding and owns bytes',
    () {
      final bytes = Uint8List(8 * 36);
      for (var y = 0; y < 8; y++) {
        for (var x = 0; x < 8; x++) {
          final i = y * 8 + x, p = y * 36 + x * 4;
          bytes.setRange(p, p + 4, [
            (i ~/ 16) * 85,
            ((i ~/ 4) % 4) * 85,
            (i % 4) * 85,
            255,
          ]);
        }
      }
      final lut = HaldLookup.fromImage(
        ImageData(
          pixels: bytes,
          size: PhysicalSize(8, 8),
          rowStride: 36,
          format: PixelFormat.bgra8,
        ),
      );
      bytes.fillRange(0, bytes.length, 0);
      expect(lut.size, 4);
      for (var i = 0; i < 64; i++) {
        expect(lut.bytes.sublist(i * 4, i * 4 + 4), [
          (i % 4) * 85,
          ((i ~/ 4) % 4) * 85,
          (i ~/ 16) * 85,
          255,
        ]);
      }
      expect(() => lut.bytes[0] = 1, throwsUnsupportedError);
    },
  );
  test(
    'Hald rejects noncubic, nonsquare, premultiplied and oversized input',
    () {
      for (final size in [
        PhysicalSize(8, 7),
        PhysicalSize(7, 7),
        PhysicalSize(1, 1),
        PhysicalSize(729, 729),
      ]) {
        expect(
          () => HaldLookup.fromImage(
            ImageData(
              pixels: Uint8List(size.width * size.height * 4),
              size: size,
            ),
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => HaldLookup.fromImage(
          ImageData(
            pixels: Uint8List(256),
            size: PhysicalSize(8, 8),
            alphaMode: AlphaMode.premultiplied,
          ),
        ),
        throwsArgumentError,
      );
    },
  );
}
