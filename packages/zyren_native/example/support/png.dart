import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';

Uint8List png(ImageData image) {
  final width = image.size.width, height = image.size.height;
  final rows = Uint8List((width * 4 + 1) * height);
  for (var y = 0; y < height; y++) {
    rows.setRange(
      y * (width * 4 + 1) + 1,
      (y + 1) * (width * 4 + 1),
      image.pixels,
      y * image.rowStride,
    );
  }
  final header = ByteData(13)
    ..setUint32(0, width)
    ..setUint32(4, height)
    ..setUint8(8, 8)
    ..setUint8(9, 6);
  final output = BytesBuilder()..add([137, 80, 78, 71, 13, 10, 26, 10]);
  void chunk(String type, List<int> data) {
    final body = Uint8List.fromList([...ascii.encode(type), ...data]);
    var crc = 0xffffffff;
    for (final byte in body) {
      crc ^= byte;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc >>> 1) ^ ((crc & 1) == 0 ? 0 : 0xedb88320);
      }
    }
    output.add((ByteData(4)..setUint32(0, data.length)).buffer.asUint8List());
    output.add(body);
    output.add(
      (ByteData(4)..setUint32(0, (~crc) & 0xffffffff)).buffer.asUint8List(),
    );
  }

  chunk('IHDR', header.buffer.asUint8List());
  chunk('IDAT', zlib.encode(rows));
  chunk('IEND', const []);
  return output.toBytes();
}
