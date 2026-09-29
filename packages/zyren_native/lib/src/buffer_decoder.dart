import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:zyren/zyren.dart';
import 'bindings.dart' as native;

/// Meshoptimizer decoding on a CPU isolate. Calls own their input snapshot and
/// output until physical completion, including after an asset is cancelled.
final class NativeBufferDecoder implements BufferDecoder {
  static int _active = 0;
  const NativeBufferDecoder();
  @override
  Set<BufferEncoding> get encodings => const {BufferEncoding.meshopt};
  @override
  Future<Uint8List> decode(
    Uint8List bytes, {
    required BufferDecodeOptions options,
    int maxDecodedBytes = 64 * 1024 * 1024,
  }) async {
    options.validateInput(bytes, maxDecodedBytes: maxDecodedBytes);
    if (_active >= 2) {
      throw const BufferDecodeException(
        BufferDecodeError.busy,
        'Two buffer decodes are active. Retry after one completes.',
      );
    }
    _active++;
    try {
      final snapshot = TransferableTypedData.fromList([bytes]);
      return (await _run(snapshot, options)).asUnmodifiableView();
    } finally {
      _active--;
    }
  }
}

Future<Uint8List> _run(
  TransferableTypedData input,
  BufferDecodeOptions options,
) => Isolate.run(
  () => _decode(input, options),
  debugName: 'zyren-buffer-decode',
);

Uint8List _decode(
  TransferableTypedData transfer,
  BufferDecodeOptions options,
) => using((arena) {
  final bytes = transfer.materialize().asUint8List();
  final length = options.decodedByteLength;
  final input = arena<Uint8>(bytes.length), output = arena<Uint8>(length);
  input.asTypedList(bytes.length).setAll(0, bytes);
  final status = native.meshoptDecode(
    input,
    bytes.length,
    options.count,
    options.stride,
    options.mode.index,
    options.filter.index,
    output,
    length,
  );
  if (status != 0) {
    final code = switch (status) {
      1 => BufferDecodeError.invalidData,
      2 => BufferDecodeError.limitExceeded,
      3 => BufferDecodeError.busy,
      _ => BufferDecodeError.internal,
    };
    throw BufferDecodeException(code, switch (code) {
      BufferDecodeError.invalidData =>
        'Compressed buffer is malformed or truncated.',
      BufferDecodeError.limitExceeded =>
        'Compressed buffer exceeds the native byte limit.',
      BufferDecodeError.busy =>
        'Native buffer decode slots are in use. Retry after a decode completes.',
      _ => 'Native buffer decoding failed.',
    });
  }
  return Uint8List.fromList(output.asTypedList(length));
});
