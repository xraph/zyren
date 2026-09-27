import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:gpu3d/gpu3d.dart';
import 'bindings.dart' as native;

/// Bounded PNG/JPEG decoding on a CPU isolate. This creates no GPU device.
/// At most two calls from one Dart isolate may be active across all instances.
final class NativeImageDecoder implements ImageDecoder {
  static int _active = 0;
  const NativeImageDecoder();
  @override
  Future<ImageData> decode(
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

Future<ImageData> _run(TransferableTypedData input, ImageDecodeLimits limits) =>
    Isolate.run(() => _decode(input, limits), debugName: 'gpu3d-image-decode');

ImageData _decode(
  TransferableTypedData transfer,
  ImageDecodeLimits limits,
) => using((arena) {
  final bytes = transfer.materialize().asUint8List();
  final input = arena<Uint8>(bytes.length);
  final options = arena<native.NativeImageLimits>();
  final output = arena<native.NativeImagePixels>();
  try {
    input.asTypedList(bytes.length).setAll(0, bytes);
    options.ref
      ..version = 1
      ..maxDimension = limits.maxDimension
      ..maxEncodedBytes = limits.maxEncodedBytes
      ..maxDecodedBytes = limits.maxDecodedBytes
      ..maxWorkingBytes = limits.maxWorkingBytes;
    final status = native.imageDecode(input, bytes.length, options, output);
    if (status != 0) {
      final code = status >= 1 && status <= ImageDecodeError.values.length
          ? ImageDecodeError.values[status - 1]
          : ImageDecodeError.internal;
      throw ImageDecodeException(code, switch (code) {
        ImageDecodeError.invalidData => 'The image is malformed or truncated.',
        ImageDecodeError.unsupportedFormat =>
          'Only static PNG and JPEG images are supported.',
        ImageDecodeError.unsupportedColor =>
          'The image channel format is unsupported.',
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
        image.length > limits.maxDecodedBytes) {
      throw const ImageDecodeException(
        ImageDecodeError.internal,
        'Native image returned an invalid pixel descriptor.',
      );
    }
    return ImageData(
      pixels: Uint8List.fromList(image.pixels.asTypedList(image.length)),
      size: PhysicalSize(image.width, image.height),
    );
  } finally {
    native.imageFree(output);
  }
});
