import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';

BufferGeometry triangle(IndexFormat format) => BufferGeometry(
  positions: [-1, -1, 0, 1, -1, 0, 0, 1, 0],
  normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
  indices: [0, 1, 2],
  indexFormat: format,
  dynamic: true,
);

void main() {
  test('index widths own their typed storage and survive attribute edits', () {
    final geometry = triangle(IndexFormat.uint16);
    expect(geometry.indices, isA<Uint16List>());
    expect(geometry.indexFormat, IndexFormat.uint16);
    expect(() => geometry.indices[0] = 1, throwsUnsupportedError);
    geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList([-2, -1, 0]),
    );
    expect(geometry.capture().indexFormat, IndexFormat.uint16);
    expect(geometry.toNative()['index_format'], 'uint16');
    expect(PlaneGeometry().indexFormat, IndexFormat.uint32);
    expect(
      PlaneGeometry(indexFormat: IndexFormat.uint16).indices,
      isA<Uint16List>(),
    );
    expect(
      BoxGeometry(indexFormat: IndexFormat.uint16).indices,
      isA<Uint16List>(),
    );
    expect(
      SphereGeometry(indexFormat: IndexFormat.uint16).indices,
      isA<Uint16List>(),
    );
  });
  test('uint16 rejects truncation while uint32 addresses larger vertices', () {
    final positions = Float32List(65537 * 3);
    final normals = Float32List.fromList([
      for (var i = 0; i < 65537; i++) ...[0, 0, 1],
    ]);
    BufferGeometry make(IndexFormat format, List<int> indices) =>
        BufferGeometry(
          positions: positions,
          normals: normals,
          indices: indices,
          indexFormat: format,
        );
    expect(make(IndexFormat.uint16, [0, 65535, 1]).indices[1], 65535);
    expect(() => make(IndexFormat.uint16, [0, 65536, 1]), throwsArgumentError);
    expect(make(IndexFormat.uint32, [0, 65536, 1]).indices[1], 65536);
    final input = [0, 1, 2];
    final owned = make(IndexFormat.uint16, input);
    input[1] = 0;
    expect(owned.indices, [0, 1, 2]);
  });
  test(
    'compact packets count actual index bytes and retain unaligned framing',
    () {
      EncodedScenePacket packet(IndexFormat format) =>
          ScenePacketEncoder(viewId: 1).encode(
            FrameSubmission.capture(
              scene: Scene()..add(Mesh(triangle(format), UnlitMaterial())),
              camera: PerspectiveCamera(),
              size: PhysicalSize(31, 31),
            ),
          );
      final compact = packet(IndexFormat.uint16),
          wide = packet(IndexFormat.uint32);
      expect(compact.uploadedBytes, 78);
      expect(wide.uploadedBytes, 84);
      expect(
        ByteData.sublistView(compact.bytes).getUint32(4, Endian.little),
        13,
      );
      // Opcode 13 adds a four-byte patch count and saves six index bytes.
      expect(compact.bytes.length, wide.bytes.length - 2);
    },
  );
}
