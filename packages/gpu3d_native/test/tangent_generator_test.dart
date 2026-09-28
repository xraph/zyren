import 'dart:typed_data';
import 'dart:convert';
import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import '../../gpu3d/test/tangent_generator_test.dart' show mirroredQuad;

void main() {
  test(
    'morph corner bases match separately generated absolute poses',
    () async {
      final original = mirroredQuad();
      final plain = GeometryData(
        attributes: {
          ...original.attributes,
          VertexSemantic.tangent: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < 4; i++) ...[1, 0, 0, 1],
            ]),
            format: VertexFormat.float32x4,
          ),
        },
        indices: original.indices,
      );
      final target = MorphTarget(
        name: 'bend',
        positions: [0, 0, 0, .2, .3, .1, -.1, .1, .4, .1, -.3, -.2],
        normals: [
          for (var i = 0; i < 4; i++) ...[.2, .1, -.05],
        ],
        tangents: List.filled(12, 42),
      );
      final input = GeometryData(
        attributes: plain.attributes,
        indices: plain.indices,
        morphTargets: [
          target,
          MorphTarget(name: 'zero', positions: List.filled(12, 0)),
          MorphTarget(name: 'normal only', normals: List.filled(12, .1)),
        ],
      );
      final output = await const NativeTangentGenerator().generate(input);
      final base = await const NativeTangentGenerator().generate(plain);
      final absolute = GeometryData(
        attributes: {
          ...plain.attributes,
          VertexSemantic.position: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < 12; i++)
                (plain.attributes[VertexSemantic.position]!.data
                        as Float32List)[i] +
                    target.positions![i],
            ]),
            format: VertexFormat.float32x3,
          ),
          VertexSemantic.normal: VertexAttribute(
            Float32List.fromList([
              for (var i = 0; i < 12; i++)
                (plain.attributes[VertexSemantic.normal]!.data
                        as Float32List)[i] +
                    target.normals![i],
            ]),
            format: VertexFormat.float32x3,
          ),
        },
        indices: plain.indices,
      );
      final expected = await const NativeTangentGenerator().generate(absolute);
      final actualValues =
          output.attributes[VertexSemantic.tangent]!.data as Float32List;
      final baseValues =
          base.attributes[VertexSemantic.tangent]!.data as Float32List;
      final expectedValues =
          expected.attributes[VertexSemantic.tangent]!.data as Float32List;
      for (var corner = 0; corner < plain.indices.length; corner++) {
        final actualVertex = output.indices[corner];
        for (var c = 0; c < 3; c++) {
          expect(
            actualValues[actualVertex * 4 + c],
            baseValues[base.indices[corner] * 4 + c],
          );
          expect(
            actualValues[actualVertex * 4 + c] +
                output.morphTargets.first.tangents![actualVertex * 3 + c],
            closeTo(expectedValues[expected.indices[corner] * 4 + c], 1e-6),
          );
        }
      }
      expect(output.morphTargets.first.name, 'bend');
      expect(target.tangents!.first, 42);
      expect(output.morphTargets[1].tangents!.every((v) => v == 0), isTrue);
      expect(
        output.morphTargets[2].tangents!.any((v) => v.abs() > .01),
        isTrue,
      );
    },
  );

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
  test('morph jobs share limits and invalid poses release admission', () async {
    final base = mirroredQuad();
    GeometryData withTarget(MorphTarget target) => GeometryData(
      attributes: base.attributes,
      indices: base.indices,
      morphTargets: [target],
    );
    final changed = withTarget(MorphTarget(normals: List.filled(12, .1)));
    for (final limits in [
      const TangentGenerationLimits(maxWorkingBytes: 400),
      const TangentGenerationLimits(maxIterations: 1),
      const TangentGenerationLimits(maxOutputBytes: 400),
    ]) {
      await expectLater(
        generator.generate(changed, limits: limits),
        throwsA(
          isA<TangentGenerationException>().having(
            (e) => e.code,
            'code',
            TangentGenerationError.limitExceeded,
          ),
        ),
      );
    }
    for (final target in [
      MorphTarget(
        normals: [
          for (var i = 0; i < 4; i++) ...[0, 0, -1],
        ],
      ),
      MorphTarget(positions: List.filled(12, 1e16)),
    ]) {
      await expectLater(
        generator.generate(withTarget(target)),
        throwsA(
          isA<TangentGenerationException>().having(
            (e) => e.code,
            'code',
            TangentGenerationError.invalidData,
          ),
        ),
      );
    }
    expect(
      (await generator.generate(changed)).morphTargets.single.tangents,
      isNotNull,
    );
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
