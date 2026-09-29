import 'dart:typed_data';
import 'buffer_decoder.dart';

/// Optional CPU decoder for compressed triangle meshes. Failures use
/// [BufferDecodeException], shared with compressed buffer codecs.
abstract interface class CompressedMeshDecoder {
  Set<MeshEncoding> get encodings;
  Future<DecodedMeshData> decode(
    Uint8List bytes, {
    required MeshEncoding encoding,
    MeshDecodeLimits limits = const MeshDecodeLimits(),
  });
}

enum MeshEncoding { draco }

enum MeshScalarType {
  int8,
  uint8,
  int16,
  uint16,
  uint32,
  float32;

  int get byteLength => switch (this) {
    int8 || uint8 => 1,
    int16 || uint16 => 2,
    uint32 || float32 => 4,
  };
}

/// Packed little-endian values identified by the codec's unique attribute ID.
/// A decoder transfers ownership of the backing bytes when it returns a result.
final class MeshAttributeData {
  final int id, components;
  final MeshScalarType type;
  final bool normalized;
  final Uint8List bytes;
  MeshAttributeData({
    required this.id,
    required this.type,
    required this.components,
    this.normalized = false,
    required Uint8List bytes,
  }) : bytes = bytes.asUnmodifiableView();
}

final class DecodedMeshData {
  final int vertexCount;
  final Uint32List indices;
  final List<MeshAttributeData> attributes;
  DecodedMeshData({
    required this.vertexCount,
    required Uint32List indices,
    required List<MeshAttributeData> attributes,
  }) : indices = indices.asUnmodifiableView(),
       attributes = List.unmodifiable(attributes);
  int get decodedByteLength =>
      indices.lengthInBytes + attributes.fold(0, (n, a) => n + a.bytes.length);
}

/// Bounds mesh payloads and codec counts, not total process memory.
final class MeshDecodeLimits {
  final int maxEncodedBytes,
      maxDecodedBytes,
      maxVertices,
      maxTriangles,
      maxAttributes;
  const MeshDecodeLimits({
    this.maxEncodedBytes = 16 * 1024 * 1024,
    this.maxDecodedBytes = 64 * 1024 * 1024,
    this.maxVertices = 1000000,
    this.maxTriangles = 1000000,
    this.maxAttributes = 32,
  });
  void validate() {
    for (final (name, value, ceiling) in [
      ('maxEncodedBytes', maxEncodedBytes, 16 * 1024 * 1024),
      ('maxDecodedBytes', maxDecodedBytes, 64 * 1024 * 1024),
      ('maxVertices', maxVertices, 1000000),
      ('maxTriangles', maxTriangles, 1000000),
      ('maxAttributes', maxAttributes, 32),
    ]) {
      RangeError.checkValueInInterval(value, 1, ceiling, name);
    }
  }

  void validateInput(Uint8List bytes) {
    validate();
    if (bytes.isEmpty) _invalid('Compressed mesh is empty.');
    if (bytes.length > maxEncodedBytes) _limit();
  }

  void validateOutput(DecodedMeshData mesh) {
    validate();
    if (mesh.vertexCount < 1 ||
        mesh.indices.isEmpty ||
        mesh.indices.length % 3 != 0 ||
        mesh.attributes.isEmpty) {
      _invalid(
        'Decoded mesh needs vertices, attributes and complete triangles.',
      );
    }
    if (mesh.vertexCount > maxVertices ||
        mesh.indices.length ~/ 3 > maxTriangles ||
        mesh.attributes.length > maxAttributes ||
        mesh.decodedByteLength > maxDecodedBytes) {
      _limit();
    }
    final ids = <int>{};
    for (final attribute in mesh.attributes) {
      if (attribute.id < 0 ||
          attribute.id > 0xffffffff ||
          !ids.add(attribute.id) ||
          attribute.components < 1 ||
          attribute.components > 4 ||
          attribute.bytes.length !=
              mesh.vertexCount *
                  attribute.components *
                  attribute.type.byteLength ||
          (attribute.normalized &&
              (attribute.type == MeshScalarType.float32 ||
                  attribute.type == MeshScalarType.uint32))) {
        _invalid(
          'Decoded mesh attributes have invalid IDs, lengths or formats.',
        );
      }
    }
    if (mesh.indices.any((i) => i >= mesh.vertexCount)) {
      _invalid('Decoded mesh index exceeds its vertex count.');
    }
  }

  Never _invalid(String message) =>
      throw BufferDecodeException(BufferDecodeError.invalidData, message);
  Never _limit() => throw const BufferDecodeException(
    BufferDecodeError.limitExceeded,
    'Compressed mesh exceeds its decode limits.',
  );
}
