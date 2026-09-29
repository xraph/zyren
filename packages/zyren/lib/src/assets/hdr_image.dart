import 'dart:typed_data';
import '../rendering/frame_output.dart';

/// Immutable, tightly packed, top-down RGBA32F in linear sRGB.
/// RGB channels are finite and nonnegative; alpha is straight and in [0, 1].
/// The constructor copies [pixels], so callers may reuse their input storage.
final class HdrImageData {
  final Float32List pixels;
  final PhysicalSize size;
  factory HdrImageData({
    required Float32List pixels,
    required PhysicalSize size,
  }) {
    if (size.width > 4096 ||
        size.height > 4096 ||
        pixels.length != size.width * size.height * 4 ||
        pixels.lengthInBytes > 64 * 1024 * 1024) {
      throw ArgumentError(
        'HDR storage must match its dimensions within the 64 MiB profile.',
      );
    }
    for (var i = 0; i < pixels.length; i++) {
      final value = pixels[i];
      if (!value.isFinite || value < 0 || (i % 4 == 3 && value > 1)) {
        throw ArgumentError(
          'HDR pixels need finite nonnegative RGB and alpha in [0, 1].',
        );
      }
    }
    return HdrImageData._(
      Float32List.fromList(pixels).asUnmodifiableView(),
      size,
    );
  }
  HdrImageData._(this.pixels, this.size);

  /// Converts to tightly packed little-endian RGBA16F for resource-scope uploads.
  /// [scale] multiplies RGB only. Overflow above 65504 throws before upload;
  /// no tone curve, color transfer or silent clamp is applied. Half-float
  /// conversion rounds to nearest with ties to even, including subnormals.
  Uint8List toRgba16Float({double scale = 1}) {
    if (!scale.isFinite || scale < 0) {
      throw ArgumentError.value(
        scale,
        'scale',
        'Must be finite and nonnegative.',
      );
    }
    final bytes = ByteData(pixels.length * 2);
    final scratch = ByteData(8);
    for (var i = 0; i < pixels.length; i++) {
      final value = pixels[i] * (i % 4 == 3 ? 1 : scale);
      if (!value.isFinite || value > 65504) {
        throw RangeError(
          'HDR component $i exceeds float16. Reduce the upload scale.',
        );
      }
      scratch.setFloat64(0, value, Endian.little);
      final bits = scratch.getUint64(0, Endian.little);
      final exponent = ((bits >> 52) & 2047) - 1023;
      var half = 0;
      if (exponent >= -25) {
        final mantissa = (bits & 0xfffffffffffff) | 0x10000000000000;
        final shift = exponent < -14 ? 28 - exponent : 42;
        var rounded = mantissa >> shift;
        final remainder = mantissa & ((1 << shift) - 1);
        final midpoint = 1 << (shift - 1);
        if (remainder > midpoint || (remainder == midpoint && rounded.isOdd)) {
          rounded++;
        }
        half = exponent < -14 ? rounded : ((exponent + 14) << 10) + rounded;
      }
      bytes.setUint16(i * 2, half, Endian.little);
    }
    return bytes.buffer.asUint8List();
  }
}
