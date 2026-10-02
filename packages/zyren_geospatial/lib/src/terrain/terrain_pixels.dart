import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

abstract final class TerrainCompositionPool {
  static int _active = 0;
  static final _queue = Queue<Completer<void>>();
  static Future<T> run<T>(
    Future<T> Function() work,
    LoadCancellation cancellation,
  ) async {
    if (_active < 2) {
      _active++;
    } else {
      if (_queue.length >= 16) {
        throw AssetLoadException(
          AssetLoadError.limitExceeded,
          'Terrain composition queue is full.',
        );
      }
      final gate = Completer<void>();
      _queue.add(gate);
      await gate.future;
    }
    try {
      cancellation.throwIfCancelled();
      final result = await work();
      cancellation.throwIfCancelled();
      return result;
    } finally {
      if (_queue.isEmpty) {
        _active--;
      } else {
        _queue.removeFirst().complete();
      }
    }
  }
}

final _gamma = List<double>.generate(256, (i) {
  final c = i / 255;
  return c <= .04045 ? c / 12.92 : math.pow((c + .055) / 1.055, 2.4).toDouble();
});

List<double> sampleTerrainPixels(ImageData image, double u, double v) {
  final x = (u * image.size.width - .5).clamp(0.0, image.size.width - 1.0);
  final y = (v * image.size.height - .5).clamp(0.0, image.size.height - 1.0);
  final x0 = x.floor(), y0 = y.floor(), fx = x - x0, fy = y - y0;
  final result = List<double>.filled(4, 0);
  for (final (px, py, weight) in [
    (x0, y0, (1 - fx) * (1 - fy)),
    (math.min(x0 + 1, image.size.width - 1), y0, fx * (1 - fy)),
    (x0, math.min(y0 + 1, image.size.height - 1), (1 - fx) * fy),
    (
      math.min(x0 + 1, image.size.width - 1),
      math.min(y0 + 1, image.size.height - 1),
      fx * fy,
    ),
  ]) {
    final at = py * image.rowStride + px * 4;
    final alpha = image.alphaMode == AlphaMode.opaque
        ? 1.0
        : image.pixels[at + 3] / 255;
    result[3] += alpha * weight;
    for (var c = 0; c < 3; c++) {
      final channel = image.format == PixelFormat.bgra8 && c != 1 ? 2 - c : c;
      final encoded = image.pixels[at + channel];
      var value = encoded / 255;
      if (image.alphaMode == AlphaMode.premultiplied) {
        value = alpha == 0 ? 0 : (value / alpha).clamp(0, 1);
      }
      final linear = image.colorSpace == ColorSpace.linear
          ? value
          : image.alphaMode != AlphaMode.premultiplied
          ? _gamma[encoded]
          : value <= .04045
          ? value / 12.92
          : math.pow((value + .055) / 1.055, 2.4).toDouble();
      result[c] += linear * alpha * weight;
    }
  }
  return result;
}

void storeTerrainPixel(Uint8List pixels, int at, List<double> result) {
  for (var c = 0; c < 3; c++) {
    final value = result[3] == 0
        ? 0.0
        : (result[c] / result[3]).clamp(0.0, 1.0);
    final encoded = value <= .0031308
        ? value * 12.92
        : 1.055 * math.pow(value, 1 / 2.4) - .055;
    pixels[at + c] = (encoded * 255).round().clamp(0, 255);
  }
  pixels[at + 3] = (result[3] * 255).round().clamp(0, 255);
}
