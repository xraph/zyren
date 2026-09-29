import 'dart:typed_data';
import '../rendering/frame_output.dart';

/// CPU image decoding. Implementations do not need a scene or GPU device.
abstract interface class ImageDecoder {
  Future<ImageData> decode(
    Uint8List bytes, {
    ImageDecodeLimits limits = const ImageDecodeLimits(),
  });
}

enum ImageDecodeError {
  invalidData,
  unsupportedFormat,
  unsupportedColor,
  limitExceeded,
  busy,
  internal,
}

final class ImageDecodeException implements Exception {
  final ImageDecodeError code;
  final String message;
  const ImageDecodeException(this.code, this.message);
  @override
  String toString() => 'ImageDecodeException(${code.name}): $message';
}

/// Limits may reduce the native profile, but cannot raise its hard ceilings.
final class ImageDecodeLimits {
  final int maxEncodedBytes, maxDecodedBytes, maxDimension;

  /// Native decode admission reservation, including estimated workspace.
  /// This excludes Dart transfer storage and is not a process-memory cap.
  final int maxWorkingBytes;
  const ImageDecodeLimits({
    this.maxEncodedBytes = 16 * 1024 * 1024,
    this.maxDecodedBytes = 64 * 1024 * 1024,
    this.maxWorkingBytes = 128 * 1024 * 1024,
    this.maxDimension = 4096,
  });
  void validate() {
    for (final (value, ceiling, name) in [
      (maxEncodedBytes, 16 * 1024 * 1024, 'maxEncodedBytes'),
      (maxDecodedBytes, 64 * 1024 * 1024, 'maxDecodedBytes'),
      (maxWorkingBytes, 128 * 1024 * 1024, 'maxWorkingBytes'),
      (maxDimension, 4096, 'maxDimension'),
    ]) {
      RangeError.checkValueInInterval(value, 1, ceiling, name);
    }
  }

  void validateInput(Uint8List bytes) {
    validate();
    if (bytes.length > maxEncodedBytes) {
      throw const ImageDecodeException(
        ImageDecodeError.limitExceeded,
        'Encoded image exceeds the byte limit.',
      );
    }
    if (bytes.isEmpty) {
      throw const ImageDecodeException(
        ImageDecodeError.invalidData,
        'Image input is empty.',
      );
    }
  }
}
