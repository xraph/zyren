import 'dart:typed_data';
import 'package:zyren/zyren.dart';

TextureImageData decodeTexturePacket(
  Uint8List packet,
  ImageDecodeLimits limits,
) {
  Never invalid() => throw const ImageDecodeException(
    ImageDecodeError.invalidData,
    'Invalid native texture packet.',
  );
  if (packet.length < 20) invalid();
  final data = ByteData.sublistView(packet);
  final width = data.getUint32(0, Endian.little),
      height = data.getUint32(4, Endian.little);
  final storage = data.getUint32(8, Endian.little),
      count = data.getUint32(12, Endian.little);
  if (width < 1 ||
      height < 1 ||
      width > limits.maxDimension ||
      height > limits.maxDimension ||
      storage >= TextureFormat.values.length ||
      storage == 2 ||
      (storage >= 3 && (width % 4 != 0 || height % 4 != 0)) ||
      count < 1 ||
      count > (width > height ? width : height).bitLength) {
    invalid();
  }
  final format = TextureFormat.values[storage];
  var offset = 16, total = 0;
  final levels = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    if (offset + 4 > packet.length) invalid();
    final length = data.getUint32(offset, Endian.little);
    offset += 4;
    final w = (width >> i).clamp(1, width), h = (height >> i).clamp(1, height);
    total += length;
    if (length != format.levelByteLength(w, h) ||
        offset + length > packet.length ||
        total > limits.maxDecodedBytes) {
      invalid();
    }
    levels.add(Uint8List.sublistView(packet, offset, offset + length));
    offset += length;
  }
  if (offset != packet.length) invalid();
  if (format.isCompressed) {
    return TextureImageData.compressed(
      width: width,
      height: height,
      format: format,
      blocks: levels.first,
      mipmaps: levels.sublist(1),
    );
  }
  return TextureImageData.rgba(
    width: width,
    height: height,
    pixels: levels.first,
    mipmaps: levels.sublist(1),
    format: format,
  );
}
