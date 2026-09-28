import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import '../../gpu3d/test/tangent_generator_test.dart' show mirroredQuad;

void main() {
  const generator = NativeTangentGenerator();
  test('curved mirrored geometry matches the unmodified reference', () async {
    final fixture =
        jsonDecode(
              File(
                '../../test_assets/geometry/mikktspace-curved-mirror.json',
              ).readAsStringSync(),
            )
            as Map;
    VertexAttribute attribute(String key, VertexFormat format) =>
        VertexAttribute(
          Float32List.fromList(
            (fixture[key] as List)
                .cast<num>()
                .map((v) => v.toDouble())
                .toList(),
          ),
          format: format,
        );
    final input = GeometryData(
      attributes: {
        VertexSemantic.position: attribute('positions', VertexFormat.float32x3),
        VertexSemantic.normal: attribute('normals', VertexFormat.float32x3),
        VertexSemantic.uv0: attribute('uvs', VertexFormat.float32x2),
      },
      indices: (fixture['indices'] as List).cast<int>(),
    );
    for (final reversed in [false, true]) {
      final order = [for (var i = 0; i < input.indices.length; i += 3) i];
      final offsets = reversed ? order.reversed.toList() : order;
      final source = GeometryData(
        attributes: input.attributes,
        indices: [
          for (final offset in offsets)
            ...input.indices.sublist(offset, offset + 3),
        ],
      );
      final output = await generator.generate(source);
      final tangents =
          output.attributes[VertexSemantic.tangent]!.data as Float32List;
      final expected = fixture['cornerTangents'] as List;
      for (var corner = 0; corner < output.indices.length; corner++) {
        final expectedCorner = offsets[corner ~/ 3] + corner % 3;
        for (var component = 0; component < 4; component++) {
          expect(
            tangents[output.indices[corner] * 4 + component],
            closeTo(expected[expectedCorner * 4 + component] as num, 1e-6),
          );
        }
      }
    }
  });
  test('MikkTSpace splits mirrored UV seams on a CPU worker', () async {
    final source = mirroredQuad();
    final generated = await generator.generate(source);
    expect(generated.layout.vertexCount, 6);
    expect(generated.attributes[VertexSemantic.tangent]!.data, [
      for (var i = 0; i < 3; i++) ...[1, 0, 0, 1],
      for (var i = 0; i < 3; i++) ...[-1, 0, 0, -1],
    ]);
    expect(source.attributes.containsKey(VertexSemantic.tangent), isFalse);
    expect(
      generated.attributes[VertexSemantic.color]!.format,
      VertexFormat.unorm8x4,
    );
  });
  test(
    'selected UV set controls generation and normals are normalized',
    () async {
      final source = mirroredQuad();
      final data = GeometryData(
        attributes: {
          ...source.attributes,
          VertexSemantic.normal: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < 4; i++) ...[0, 0, 2],
            ]),
            format: VertexFormat.float32x3,
          ),
          VertexSemantic.uv1: VertexAttribute(
            Float32List.fromList([0, 0, 0, 1, 1, 0, 0, -1]),
            format: VertexFormat.float32x2,
          ),
        },
        indices: source.indices,
      );
      final generated = await generator.generate(data, uvSet: 1);
      expect(generated.layout.vertexCount, 4);
      expect(generated.attributes[VertexSemantic.tangent]!.data, [
        for (var i = 0; i < 4; i++) ...[0, 1, 0, -1],
      ]);
    },
  );
  test('scratch and iteration failures release native reservations', () async {
    for (final limits in [
      const TangentGenerationLimits(maxWorkingBytes: 32),
      const TangentGenerationLimits(maxIterations: 1),
      const TangentGenerationLimits(maxOutputBytes: 1),
    ]) {
      await expectLater(
        generator.generate(mirroredQuad(), limits: limits),
        throwsA(
          isA<TangentGenerationException>().having(
            (e) => e.code,
            'code',
            TangentGenerationError.limitExceeded,
          ),
        ),
      );
    }
    expect((await generator.generate(mirroredQuad())).layout.vertexCount, 6);
  });
  test('degenerate positions and UVs return the reference fallback', () async {
    final source = mirroredQuad();
    for (final semantic in [VertexSemantic.position, VertexSemantic.uv0]) {
      final old = source.attributes[semantic]!;
      final data = GeometryData(
        attributes: {
          ...source.attributes,
          semantic: VertexAttribute(
            Float32List(old.data.lengthInBytes ~/ 4),
            format: old.format,
          ),
        },
        indices: source.indices,
      );
      final result = await generator.generate(data);
      final tangent =
          result.attributes[VertexSemantic.tangent]!.data as Float32List;
      expect(tangent.every((v) => v.isFinite), isTrue);
    }
  });
}
