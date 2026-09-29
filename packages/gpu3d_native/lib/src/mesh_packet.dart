import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';

DecodedMeshData decodeMeshPacket(Uint8List packet, MeshDecodeLimits limits) {
  Never invalid() => throw const BufferDecodeException(
    BufferDecodeError.invalidData,
    'Native mesh returned an invalid packet.',
  );
  if (packet.length < 12 ||
      packet.length > limits.maxDecodedBytes + 12 + limits.maxAttributes * 20) {
    invalid();
  }
  final data = ByteData.sublistView(packet);
  var offset = 0;
  int word() {
    if (offset > packet.length - 4) invalid();
    final n = data.getUint32(offset, Endian.little);
    offset += 4;
    return n;
  }

  final vertices = word(), indexCount = word(), attributeCount = word();
  if (vertices < 1 ||
      vertices > limits.maxVertices ||
      indexCount < 3 ||
      indexCount % 3 != 0 ||
      indexCount ~/ 3 > limits.maxTriangles ||
      attributeCount < 1 ||
      attributeCount > limits.maxAttributes ||
      indexCount > (packet.length - offset) ~/ 4) {
    invalid();
  }
  final indices = Uint32List(indexCount);
  for (var i = 0; i < indexCount; i++) {
    indices[i] = word();
  }
  final attributes = <MeshAttributeData>[];
  for (var i = 0; i < attributeCount; i++) {
    final id = word(),
        type = word(),
        components = word(),
        normalized = word(),
        length = word();
    if (type >= MeshScalarType.values.length ||
        normalized > 1 ||
        components < 1 ||
        components > 4 ||
        length > packet.length - offset) {
      invalid();
    }
    attributes.add(
      MeshAttributeData(
        id: id,
        type: MeshScalarType.values[type],
        components: components,
        normalized: normalized == 1,
        bytes: Uint8List.sublistView(packet, offset, offset + length),
      ),
    );
    offset += length;
  }
  if (offset != packet.length) invalid();
  final mesh = DecodedMeshData(
    vertexCount: vertices,
    indices: indices,
    attributes: attributes,
  );
  limits.validateOutput(mesh);
  return mesh;
}
