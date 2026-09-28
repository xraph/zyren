import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:zyren/zyren.dart';
import 'bindings.dart' as native;
import 'texture_packet.dart';

/// CPU Basis Universal transcoding to RGBA8, preserving authored mip levels.
/// Two calls may run per Dart isolate. Native workspace admission is shared
/// with image decoding; no renderer or GPU device is created.
final class NativeTextureDecoder implements TextureDecoder {
  static int _active = 0;
  const NativeTextureDecoder();
  @override
  Set<TextureEncoding> get encodings => const {TextureEncoding.ktx2Basis};
  @override
  Future<TextureImageData> decode(
    Uint8List bytes, {
    required TextureEncoding encoding,
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    limits.validateInput(bytes);
    if (_active >= 2) {
      throw const ImageDecodeException(
        ImageDecodeError.busy,
        'Two texture decodes are already active. Retry after one completes.',
      );
    }
    _active++;
    try {
      final snapshot = TransferableTypedData.fromList([bytes]);
      return await _run(snapshot, limits);
    } finally {
      _active--;
    }
  }
}

Future<TextureImageData> _run(
  TransferableTypedData input,
  ImageDecodeLimits limits,
) => Isolate.run(
  () => _decode(input, limits),
  debugName: 'zyren-texture-decode',
);

TextureImageData _decode(
  TransferableTypedData transfer,
  ImageDecodeLimits limits,
) => using((arena) {
  final bytes = transfer.materialize().asUint8List();
  final input = arena<Uint8>(bytes.length);
  final options = arena<native.NativeImageLimits>();
  final output = arena<native.NativeTextureBytes>();
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    options.ref
      ..version = 1
      ..maxDimension = limits.maxDimension
      ..maxEncodedBytes = limits.maxEncodedBytes
      ..maxDecodedBytes = limits.maxDecodedBytes
      ..maxWorkingBytes = limits.maxWorkingBytes;
    final status = native.ktx2Decode(input, bytes.length, options, output);
    if (status != 0) {
      final code = status >= 1 && status <= ImageDecodeError.values.length
          ? ImageDecodeError.values[status - 1]
          : ImageDecodeError.internal;
      throw ImageDecodeException(code, switch (code) {
        ImageDecodeError.invalidData =>
          'The KTX2 texture is malformed or truncated.',
        ImageDecodeError.unsupportedFormat =>
          'The KTX2 layout or Basis encoding is unsupported.',
        ImageDecodeError.unsupportedColor =>
          'The KTX2 color metadata is unsupported.',
        ImageDecodeError.limitExceeded =>
          'The texture exceeds its decode limits.',
        ImageDecodeError.busy =>
          'The native image and texture budget is in use.',
        ImageDecodeError.internal => 'The native texture decoder failed.',
      });
    }
    if (output.ref.data == nullptr ||
        output.ref.length > limits.maxDecodedBytes + 68) {
      throw const ImageDecodeException(
        ImageDecodeError.internal,
        'Invalid native texture descriptor.',
      );
    }
    return decodeTexturePacket(
      output.ref.data.asTypedList(output.ref.length),
      limits,
    );
  } finally {
    native.ktx2Free(output);
  }
});
