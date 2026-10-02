import 'dart:typed_data';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test('HDR data owns finite linear pixels and preserves values above one', () {
    final source = Float32List.fromList([.25, 2, 8, .5]);
    final image = HdrImageData(pixels: source, size: PhysicalSize(1, 1));
    source[0] = 10;
    expect(image.pixels, [.25, 2, 8, .5]);
    expect(() => image.pixels[0] = 0, throwsUnsupportedError);
    expect(image.toRgba16Float(), [0, 0x34, 0, 0x40, 0, 0x48, 0, 0x38]);
    expect(image.toRgba16Float(scale: .5), [
      0,
      0x30,
      0,
      0x3c,
      0,
      0x44,
      0,
      0x38,
    ]);
  });
  test('half conversion rounds ties to even and keeps subnormals', () {
    for (final (value, expected) in [
      (0.0, 0),
      (1.0, 0x3c00),
      (65504.0, 0x7bff),
      (1.00048828125, 0x3c00),
      (1.00146484375, 0x3c02),
      (0.0000000298023223876953125, 0),
      (0.000000059604644775390625, 1),
      (0.0000000894069671630859375, 2),
      (0.00006103515625, 0x400),
    ]) {
      final image = HdrImageData(
        pixels: Float32List.fromList([value, 0, 0, 1]),
        size: PhysicalSize(1, 1),
      );
      expect(
        ByteData.sublistView(image.toRgba16Float()).getUint16(0, Endian.little),
        expected,
        reason: '$value',
      );
    }
  });
  test('all nonnegative finite half-float values round trip exactly', () {
    final source = Float32List(0x7c00 * 4);
    for (var bits = 0; bits < 0x7c00; bits++) {
      final exponent = bits >> 10;
      final fraction = bits & 1023;
      source[bits * 4] = exponent == 0
          ? fraction * math.pow(2, -24).toDouble()
          : (1 + fraction / 1024) * math.pow(2, exponent - 15).toDouble();
      source[bits * 4 + 3] = 1;
    }
    final image = HdrImageData(pixels: source, size: PhysicalSize(256, 124));
    final output = ByteData.sublistView(image.toRgba16Float());
    for (var bits = 0; bits < 0x7c00; bits++) {
      expect(output.getUint16(bits * 8, Endian.little), bits);
    }
  });
  test('upload scale does not round twice around a half-float midpoint', () {
    final image = HdrImageData(
      pixels: Float32List.fromList([1, 0, 0, 1]),
      size: PhysicalSize(1, 1),
    );
    for (final (scale, bits) in [
      (1.000488281251, 0x3c01),
      (1.000488281249, 0x3c00),
    ]) {
      expect(
        ByteData.sublistView(
          image.toRgba16Float(scale: scale),
        ).getUint16(0, Endian.little),
        bits,
      );
    }
  });
  test('invalid HDR data and float16 overflow fail explicitly', () {
    for (final value in [double.nan, double.infinity, -1.0]) {
      expect(
        () => HdrImageData(
          pixels: Float32List.fromList([value, 0, 0, 1]),
          size: PhysicalSize(1, 1),
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => HdrImageData(pixels: Float32List(3), size: PhysicalSize(1, 1)),
      throwsArgumentError,
    );
    expect(
      () => HdrImageData(
        pixels: Float32List.fromList([0, 0, 0, 2]),
        size: PhysicalSize(1, 1),
      ),
      throwsArgumentError,
    );
    final image = HdrImageData(
      pixels: Float32List.fromList([131008, 0, 0, 1]),
      size: PhysicalSize(1, 1),
    );
    expect(image.toRgba16Float, throwsRangeError);
    expect(
      ByteData.sublistView(
        image.toRgba16Float(scale: .5),
      ).getUint16(0, Endian.little),
      0x7bff,
    );
    for (final scale in [double.nan, double.infinity, -1.0]) {
      expect(() => image.toRgba16Float(scale: scale), throwsArgumentError);
    }
  });
}
