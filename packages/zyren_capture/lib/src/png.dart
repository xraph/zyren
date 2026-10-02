import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/rendering.dart';

/// Lossless PNG for explicit native RGBA8 sRGB readback. Converts premultiplied
/// channels to straight alpha, and ignores backend row padding.
Uint8List encodeCapturePng(ImageData image) {
  if (image.format != PixelFormat.rgba8 ||
      image.colorSpace != ColorSpace.srgb) {
    throw UnsupportedError('PNG capture requires RGBA8 sRGB pixels.');
  }
  final width = image.size.width, height = image.size.height;
  final rows = Uint8List((width * 4 + 1) * height);
  for (var y = 0; y < height; y++) {
    final offset = y * (width * 4 + 1) + 1;
    for (var x = 0; x < width; x++) {
      final source = y * image.rowStride + x * 4, target = offset + x * 4;
      final a = image.alphaMode == AlphaMode.opaque
          ? 255
          : image.pixels[source + 3];
      for (var c = 0; c < 3; c++) {
        final channel = image.pixels[source + c];
        rows[target + c] = image.alphaMode == AlphaMode.premultiplied
            ? (a == 0 ? 0 : (channel * 255 / a).round().clamp(0, 255))
            : channel;
      }
      rows[target + 3] = a;
    }
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final out = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = Uint8List.fromList([...ascii.encode(type), ...data]);
    var crc = 0xffffffff;
    for (final byte in body) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >>> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
      }
    }
    out.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    out.add(body);
    out.add(
      (ByteData(4)..setUint32(0, (~crc) & 0xffffffff)).buffer.asUint8List(),
    );
  }

  chunk('IHDR', header.buffer.asUint8List());
  chunk('sRGB', [0]);
  chunk('IDAT', zlib.encode(rows));
  chunk('IEND', []);
  return out.takeBytes();
}
