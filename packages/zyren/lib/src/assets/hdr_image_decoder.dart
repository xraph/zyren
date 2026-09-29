import 'dart:typed_data';
import 'hdr_image.dart';
import 'image_decoder.dart';

/// CPU HDR decoding with float-byte accounting, independent of any GPU device.
abstract interface class HdrImageDecoder {
  Future<HdrImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  });
}
