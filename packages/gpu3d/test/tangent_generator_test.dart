import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

GeometryData mirroredQuad() => GeometryData(
  attributes: {
    VertexSemantic.position: VertexAttribute(
      Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0, -1, 0, 0]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.normal: VertexAttribute(
      Float32List.fromList([
        for (var i = 0; i < 4; i++) ...[0, 0, 1],
      ]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.uv0: VertexAttribute(
      Float32List.fromList([0, 0, 1, 0, 0, 1, 1, 0]),
      format: VertexFormat.float32x2,
    ),
    VertexSemantic.color: VertexAttribute(
      Uint8List.fromList([
        1,
        2,
        3,
        255,
        4,
        5,
        6,
        255,
        7,
        8,
        9,
        255,
        10,
        11,
        12,
        255,
      ]),
      format: VertexFormat.unorm8x4,
    ),
    VertexSemantic.joints: VertexAttribute(
      Uint16List.fromList([
        for (var i = 0; i < 4; i++) ...[i, 2, 3, 4],
      ]),
      format: VertexFormat.uint16x4,
    ),
  },
  indices: [0, 1, 2, 0, 2, 3],
  indexFormat: IndexFormat.uint16,
);

void main() {
  test('seam splitting promotes indices beyond the uint16 vertex range', () {
    const count = 32769;
    final geometry = GeometryData(
      attributes: {
        VertexSemantic.position: VertexAttribute(
          Float32List(count * 3),
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.normal: VertexAttribute(
          Float32List.fromList([
            for (var i = 0; i < count; i++) ...[0, 0, 1],
          ]),
          format: VertexFormat.float32x3,
        ),
      },
      indices: [
        for (var repeat = 0; repeat < 2; repeat++)
          for (var i = 0; i < count; i++) i,
      ],
      indexFormat: IndexFormat.uint16,
    );
    final output = geometry.withCornerTangents(
      Float32List.fromList([
        for (var i = 0; i < count; i++) ...[1, 0, 0, 1],
        for (var i = 0; i < count; i++) ...[-1, 0, 0, -1],
      ]),
    );
    expect(output.layout.vertexCount, 65538);
    expect(output.indexFormat, IndexFormat.uint32);
    expect(output.indices.last, 65537);
  });

  test('corner tangents split mirrored seams and preserve every attribute', () {
    final input = mirroredQuad();
    final corners = Float32List.fromList([
      for (var i = 0; i < 3; i++) ...[1, 0, 0, 1],
      for (var i = 0; i < 3; i++) ...[-1, 0, 0, -1],
    ]);
    final result = input.withCornerTangents(corners);
    expect(result.layout.vertexCount, 6);
    expect(result.indices, [0, 1, 2, 3, 4, 5]);
    expect(result.indexFormat, IndexFormat.uint16);
    expect(input.layout.vertexCount, 4);
    expect(input.attributes.containsKey(VertexSemantic.tangent), isFalse);
    expect(
      result.attributes[VertexSemantic.color]!.format,
      VertexFormat.unorm8x4,
    );
    expect(result.attributes[VertexSemantic.color]!.data, [
      1,
      2,
      3,
      255,
      4,
      5,
      6,
      255,
      7,
      8,
      9,
      255,
      1,
      2,
      3,
      255,
      7,
      8,
      9,
      255,
      10,
      11,
      12,
      255,
    ]);
    expect(result.attributes[VertexSemantic.joints]!.data, [
      0,
      2,
      3,
      4,
      1,
      2,
      3,
      4,
      2,
      2,
      3,
      4,
      0,
      2,
      3,
      4,
      2,
      2,
      3,
      4,
      3,
      2,
      3,
      4,
    ]);
    expect(result.attributes[VertexSemantic.tangent]!.data, corners);
    corners[0] = 0;
    expect(
      (result.attributes[VertexSemantic.tangent]!.data as Float32List)[0],
      1,
    );
  });
  test('equal tangent corners retain indexed sharing', () {
    final result = mirroredQuad().withCornerTangents(
      Float32List.fromList([
        for (var i = 0; i < 6; i++) ...[1, 0, 0, 1],
      ]),
    );
    expect(result.layout.vertexCount, 4);
    expect(result.indices, [0, 1, 2, 0, 2, 3]);
    final source = mirroredQuad();
    final triangle = GeometryData(
      attributes: source.attributes,
      indices: [0, 1, 2],
    );
    final compact = triangle.withCornerTangents(
      Float32List.fromList([
        for (var i = 0; i < 3; i++) ...[1, 0, 0, 1],
      ]),
    );
    expect(compact.layout.vertexCount, 3);
    expect(compact.indices, [0, 1, 2]);
  });
  test('tangent validation and output budget reject before publication', () {
    final input = mirroredQuad();
    for (final values in [
      Float32List(4),
      Float32List(24),
      Float32List.fromList([
        for (var i = 0; i < 6; i++) ...[1, 0, 0, 0],
      ]),
    ]) {
      expect(
        () => input.withCornerTangents(values),
        throwsA(isA<TangentGenerationException>()),
      );
    }
    final corners = Float32List.fromList([
      for (var i = 0; i < 6; i++) ...[1, 0, 0, 1],
    ]);
    final result = input.withCornerTangents(corners);
    expect(
      () => input.withCornerTangents(
        corners,
        limits: TangentGenerationLimits(maxOutputBytes: result.byteLength - 1),
      ),
      throwsA(
        isA<TangentGenerationException>().having(
          (e) => e.code,
          'code',
          TangentGenerationError.limitExceeded,
        ),
      ),
    );
    expect(
      input
          .withCornerTangents(
            corners,
            limits: TangentGenerationLimits(maxOutputBytes: result.byteLength),
          )
          .byteLength,
      result.byteLength,
    );
  });
}
