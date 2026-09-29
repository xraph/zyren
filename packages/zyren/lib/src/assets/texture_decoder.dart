import 'dart:typed_data';
import '../resources/texture_image.dart';
import 'image_decoder.dart';

enum TextureEncoding { ktx2Basis }

/// CPU texture decoding with authored mip levels and transfer function intact.
/// Errors use [ImageDecodeException]. Limits count all returned RGBA levels.
abstract interface class TextureDecoder {
  Set<TextureEncoding> get encodings;
  Future<TextureImageData> decode(
    Uint8List bytes, {
    required TextureEncoding encoding,
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  });
}
