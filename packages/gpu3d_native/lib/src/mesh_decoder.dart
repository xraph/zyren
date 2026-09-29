import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import 'package:gpu3d/gpu3d.dart';
import 'bindings.dart' as native;
import 'mesh_packet.dart';

/// Draco 2.2 triangle decoding on a CPU isolate, with bounded output and counts.
final class NativeMeshDecoder implements CompressedMeshDecoder {
  static int _active = 0;
  const NativeMeshDecoder();
  @override
  Set<MeshEncoding> get encodings => const {MeshEncoding.draco};
  @override
  Future<DecodedMeshData> decode(
    Uint8List bytes, {
    required MeshEncoding encoding,
    MeshDecodeLimits limits = const MeshDecodeLimits(),
  }) async {
    limits.validateInput(bytes);
    if (_active >= 2) {
      throw const BufferDecodeException(
        BufferDecodeError.busy,
        'Two mesh decodes are active. Retry after one completes.',
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

Future<DecodedMeshData> _run(
  TransferableTypedData input,
  MeshDecodeLimits limits,
) => Isolate.run(() => _decode(input, limits), debugName: 'gpu3d-mesh-decode');

DecodedMeshData _decode(
  TransferableTypedData transfer,
  MeshDecodeLimits limits,
) => using((arena) {
  final bytes = transfer.materialize().asUint8List();
  final input = arena<Uint8>(bytes.length);
  final options = arena<native.NativeMeshLimits>();
  final output = arena<native.NativeMeshBytes>();
  input.asTypedList(bytes.length).setAll(0, bytes);
  options.ref
    ..version = 1
    ..maxVertices = limits.maxVertices
    ..maxTriangles = limits.maxTriangles
    ..maxAttributes = limits.maxAttributes
    ..maxEncodedBytes = limits.maxEncodedBytes
    ..maxDecodedBytes = limits.maxDecodedBytes;
  try {
    final status = native.dracoDecode(input, bytes.length, options, output);
    if (status != 0) {
      final code = switch (status) {
        1 => BufferDecodeError.invalidData,
        2 => BufferDecodeError.limitExceeded,
        3 => BufferDecodeError.unsupportedEncoding,
        4 => BufferDecodeError.busy,
        _ => BufferDecodeError.internal,
      };
      throw BufferDecodeException(code, switch (code) {
        BufferDecodeError.invalidData =>
          'Draco mesh is malformed or truncated.',
        BufferDecodeError.limitExceeded =>
          'Draco mesh exceeds its decode limits.',
        BufferDecodeError.unsupportedEncoding =>
          'Draco encoding, geometry or attribute format is unsupported.',
        BufferDecodeError.busy =>
          'Native mesh decode slots are in use. Retry after a decode completes.',
        _ => 'Native mesh decoding failed.',
      });
    }
    final length = output.ref.length;
    if (output.ref.data == nullptr ||
        length < 12 ||
        length > limits.maxDecodedBytes + 12 + limits.maxAttributes * 20) {
      throw const BufferDecodeException(
        BufferDecodeError.internal,
        'Native mesh returned an invalid byte descriptor.',
      );
    }
    return decodeMeshPacket(
      Uint8List.fromList(output.ref.data.asTypedList(length)),
      limits,
    );
  } finally {
    native.dracoFree(output);
  }
});
