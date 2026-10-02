import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

/// Source Hald pixel order: red varies fastest, then green, then blue.
/// Values are encoded color data. Image color-space metadata does not change them.
final class HaldLookup {
  final int size;
  final Uint8List bytes;
  HaldLookup._(this.size, Uint8List bytes) : bytes = bytes.asUnmodifiableView();

  factory HaldLookup.fromImage(ImageData image) {
    final width = image.size.width;
    final size = math.pow(width * width, 1 / 3).round();
    if (width != image.size.height ||
        size < 2 ||
        size > 64 ||
        size * size * size != width * width ||
        image.alphaMode == AlphaMode.premultiplied) {
      throw ArgumentError(
        'Hald images must be square, cubic, straight or opaque, with 2 to 64 voxels per axis.',
      );
    }
    final output = Uint8List(size * size * size * 4);
    final bgra = image.format == PixelFormat.bgra8;
    for (var y = 0; y < width; y++) {
      for (var x = 0; x < width; x++) {
        final from = y * image.rowStride + x * 4, to = (y * width + x) * 4;
        output[to] = image.pixels[from + (bgra ? 2 : 0)];
        output[to + 1] = image.pixels[from + 1];
        output[to + 2] = image.pixels[from + (bgra ? 0 : 2)];
        output[to + 3] = 255;
      }
    }
    return HaldLookup._(size, output);
  }
}

enum HaldInterpolation { trilinear, tetrahedral }
