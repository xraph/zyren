import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';

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
  final srgb = data.getUint32(8, Endian.little),
      count = data.getUint32(12, Endian.little);
  if (width < 1 ||
      height < 1 ||
      width > limits.maxDimension ||
      height > limits.maxDimension ||
      srgb > 1 ||
      count < 1 ||
      count > (width > height ? width : height).bitLength) {
    invalid();
  }
  var offset = 16, total = 0;
  final levels = <Uint8List>[];
  for (var i = 0; i < count; i++) {
    if (offset + 4 > packet.length) invalid();
    final length = data.getUint32(offset, Endian.little);
    offset += 4;
    final w = (width >> i).clamp(1, width), h = (height >> i).clamp(1, height);
    total += length;
    if (length != w * h * 4 ||
        offset + length > packet.length ||
        total > limits.maxDecodedBytes) {
      invalid();
    }
    levels.add(Uint8List.sublistView(packet, offset, offset + length));
    offset += length;
  }
  if (offset != packet.length) invalid();
  return TextureImageData.rgba(
    width: width,
    height: height,
    pixels: levels.first,
    mipmaps: levels.sublist(1),
    format: srgb == 1 ? TextureFormat.rgba8UnormSrgb : TextureFormat.rgba8Unorm,
  );
}
