import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

Uint8List halfTable(int width, int height) {
  final data = ByteData(width * height * 8);
  for (var i = 0; i < width * height * 4; i++) {
    data.setUint16(
      i * 2,
      i % 4 == 3 ? 0x3c00 : 0x3000 + i % 1024,
      Endian.little,
    );
  }
  return data.buffer.asUint8List();
}

/// Writes a separate planar, north-first EXR from bottom-first interleaved halves.
Uint8List tableExr(
  int width,
  int height,
  Uint8List rgba, {
  int compression = 3,
}) {
  Uint8List ints(List<int> values) {
    final data = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      data.setInt32(i * 4, values[i], Endian.little);
    }
    return data.buffer.asUint8List();
  }

  final out = BytesBuilder();
  out.add(ints([20000630, 2]));
  void attr(String name, String type, List<int> value) {
    out.add([...ascii.encode(name), 0, ...ascii.encode(type), 0]);
    out.add(ints([value.length]));
    out.add(value);
  }

  attr('channels', 'chlist', [
    for (final name in ['A', 'B', 'G', 'R']) ...[
      ...ascii.encode(name),
      0,
      ...ints([1]),
      0,
      0,
      0,
      0,
      ...ints([1, 1]),
    ],
    0,
  ]);
  attr('compression', 'compression', [compression]);
  attr('dataWindow', 'box2i', ints([0, 0, width - 1, height - 1]));
  attr('displayWindow', 'box2i', ints([0, 0, width - 1, height - 1]));
  attr('lineOrder', 'lineOrder', [0]);
  attr('pixelAspectRatio', 'float', ints([0x3f800000]));
  attr('screenWindowCenter', 'v2f', ints([0, 0]));
  attr('screenWindowWidth', 'float', ints([0x3f800000]));
  out.add([0]);
  final rows = compression == 3 ? 16 : 1;
  final blocks = <Uint8List>[];
  for (var y = 0; y < height; y += rows) {
    final raw = BytesBuilder();
    for (var row = y; row < y + rows && row < height; row++) {
      for (final channel in [3, 2, 1, 0]) {
        for (var x = 0; x < width; x++) {
          final at = ((height - row - 1) * width + x) * 8 + channel * 2;
          raw.add(rgba.sublist(at, at + 2));
        }
      }
    }
    final plain = raw.takeBytes();
    var encoded = plain;
    if (compression != 0) {
      final reordered = Uint8List.fromList([
        for (var i = 0; i < plain.length; i += 2) plain[i],
        for (var i = 1; i < plain.length; i += 2) plain[i],
      ]);
      for (var i = reordered.length - 1; i > 0; i--) {
        reordered[i] = (reordered[i] - reordered[i - 1] + 128) & 255;
      }
      final zipped = Uint8List.fromList(ZLibEncoder().convert(reordered));
      if (zipped.length < plain.length) encoded = zipped;
    }
    blocks.add(
      Uint8List.fromList([
        ...ints([y, encoded.length]),
        ...encoded,
      ]),
    );
  }
  var offset = out.length + blocks.length * 8;
  for (final block in blocks) {
    out.add(
      (ByteData(8)..setUint64(0, offset, Endian.little)).buffer.asUint8List(),
    );
    offset += block.length;
  }
  blocks.forEach(out.add);
  return out.takeBytes();
}
