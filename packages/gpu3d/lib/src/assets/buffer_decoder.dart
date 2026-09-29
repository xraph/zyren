import 'dart:typed_data';

/// CPU buffer decoding supplied by an optional runtime, without a GPU device.
abstract interface class BufferDecoder {
  Set<BufferEncoding> get encodings;
  Future<Uint8List> decode(
    Uint8List bytes, {
    required BufferDecodeOptions options,
    int maxDecodedBytes = 64 * 1024 * 1024,
  });
}

enum BufferEncoding { meshopt }

enum BufferDecodeMode { attributes, triangles, indices }

enum BufferDecodeFilter { none, octahedral, quaternion, exponential }

enum BufferDecodeError {
  invalidData,
  unsupportedEncoding,
  limitExceeded,
  busy,
  internal,
}

final class BufferDecodeException implements Exception {
  final BufferDecodeError code;
  final String message;
  const BufferDecodeException(this.code, this.message);
  @override
  String toString() => 'BufferDecodeException(${code.name}): $message';
}

/// Layout of the decoded buffer. Limits are checked before multiplication or
/// allocation. The fixed profile permits up to 64 MiB of output per call.
final class BufferDecodeOptions {
  final BufferEncoding encoding;
  final BufferDecodeMode mode;
  final BufferDecodeFilter filter;
  final int count, stride;
  const BufferDecodeOptions({
    required this.encoding,
    required this.count,
    required this.stride,
    this.mode = BufferDecodeMode.attributes,
    this.filter = BufferDecodeFilter.none,
  });

  int get decodedByteLength {
    validate();
    return count * stride;
  }

  void validate() {
    if (count < 1 ||
        stride < 1 ||
        stride > 256 ||
        (mode == BufferDecodeMode.attributes && stride % 4 != 0) ||
        (mode != BufferDecodeMode.attributes &&
            (stride != 2 && stride != 4 ||
                filter != BufferDecodeFilter.none)) ||
        (mode == BufferDecodeMode.triangles && count % 3 != 0) ||
        (filter == BufferDecodeFilter.octahedral &&
            stride != 4 &&
            stride != 8) ||
        (filter == BufferDecodeFilter.quaternion && stride != 8)) {
      throw const BufferDecodeException(
        BufferDecodeError.invalidData,
        'Compressed buffer count, stride, mode or filter is invalid.',
      );
    }
    if (count > 64 * 1024 * 1024 ~/ stride) {
      throw const BufferDecodeException(
        BufferDecodeError.limitExceeded,
        'Decoded buffer exceeds the 64 MiB limit.',
      );
    }
  }

  void validateInput(
    Uint8List bytes, {
    int maxDecodedBytes = 64 * 1024 * 1024,
  }) {
    validate();
    if (bytes.isEmpty) {
      throw const BufferDecodeException(
        BufferDecodeError.invalidData,
        'Compressed buffer is empty.',
      );
    }
    if (bytes.length > 16 * 1024 * 1024 ||
        decodedByteLength > maxDecodedBytes) {
      throw const BufferDecodeException(
        BufferDecodeError.limitExceeded,
        'Compressed buffer exceeds its byte budget.',
      );
    }
  }
}
