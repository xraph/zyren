import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:zyren/zyren.dart';
import 'bindings.dart' as native;

/// Bounded Radiance RGBE decoding on a CPU isolate, without a GPU device.
/// Flat, legacy and component RLE data normalize all eight axis orientations.
/// Values are kept as stored; EXPOSURE and COLORCORR are not reapplied.
/// Missing primaries assume linear sRGB for environment-map compatibility.
/// Explicit other primaries, XYZE and non-square pixels are unsupported.
/// At most two calls from one Dart isolate may be active across all instances.
final class NativeHdrImageDecoder implements HdrImageDecoder {
  static int _active = 0;
  const NativeHdrImageDecoder();
  @override
  Future<HdrImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  }) async {
    limits.validateInput(bytes);
    if (_active >= 2) {
      throw const ImageDecodeException(
        ImageDecodeError.busy,
        'Two image decodes are already active. Retry after one completes.',
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

Future<HdrImageData> _run(
  TransferableTypedData input,
  ImageDecodeLimits limits,
) => Isolate.run(() => _decode(input, limits), debugName: 'zyren-hdr-decode');

HdrImageData _decode(
  TransferableTypedData transfer,
  ImageDecodeLimits limits,
) => using((arena) {
  final bytes = transfer.materialize().asUint8List();
  final input = arena<Uint8>(bytes.length);
  final options = arena<native.NativeImageLimits>();
  final output = arena<native.NativeHdrImagePixels>();
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    options.ref
      ..version = 1
      ..maxDimension = limits.maxDimension
      ..maxEncodedBytes = limits.maxEncodedBytes
      ..maxDecodedBytes = limits.maxDecodedBytes
      ..maxWorkingBytes = limits.maxWorkingBytes;
    final status = native.hdrImageDecode(input, bytes.length, options, output);
    if (status != 0) {
      final code = status >= 1 && status <= ImageDecodeError.values.length
          ? ImageDecodeError.values[status - 1]
          : ImageDecodeError.internal;
      throw ImageDecodeException(code, switch (code) {
        ImageDecodeError.invalidData => 'The image is malformed or truncated.',
        ImageDecodeError.unsupportedFormat =>
          'Only Radiance RGBE HDR images are supported.',
        ImageDecodeError.unsupportedColor =>
          'HDR requires RGBE, linear-sRGB primaries and square pixels.',
        ImageDecodeError.limitExceeded =>
          'The image exceeds its decode limits.',
        ImageDecodeError.busy =>
          'The native image decode budget is in use. Retry after an active decode completes.',
        ImageDecodeError.internal => 'The native image decoder failed.',
      });
    }
    final image = output.ref;
    if (image.pixels == nullptr ||
        image.width < 1 ||
        image.height < 1 ||
        image.width > limits.maxDimension ||
        image.height > limits.maxDimension ||
        image.length != image.width * image.height * 4 ||
        image.length * 4 > limits.maxDecodedBytes) {
      throw const ImageDecodeException(
        ImageDecodeError.internal,
        'Native image returned an invalid pixel descriptor.',
      );
    }
    return HdrImageData(
      pixels: image.pixels.asTypedList(image.length),
      size: PhysicalSize(image.width, image.height),
    );
  } finally {
    native.hdrImageFree(output);
  }
});
