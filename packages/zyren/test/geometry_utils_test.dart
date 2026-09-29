import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test('corner expansion preserves packed colors and morph deltas', () {
    final plane = PlaneGeometry();
    final source = BufferGeometry.fromAttributes(
      attributes: {
        ...plane.attributes,
        VertexSemantic.color: VertexAttribute(
          Uint8List.fromList([
            255,
            0,
            0,
            255,
            0,
            255,
            0,
            255,
            0,
            0,
            255,
            255,
            255,
            255,
            255,
            255,
          ]),
          format: VertexFormat.unorm8x4,
        ),
      },
      indices: plane.indices,
      morphTargets: [
        MorphTarget(
          name: 'rise',
          positions: [
            for (var i = 0; i < 4; i++) ...[0, 0, i.toDouble()],
          ],
        ),
      ],
    );
    final expanded = GeometryUtils.toNonIndexed(source);
    expect(expanded.vertexCount, 6);
    expect(expanded.morphTargets.single.positions, [
      for (final i in source.indices) ...[0, 0, i.toDouble()],
    ]);
    expect(
      expanded.attributes[VertexSemantic.color]!.format,
      VertexFormat.unorm8x4,
    );
    expect(source.vertexCount, 4);
    expect(() => GeometryUtils.merge([source]), throwsArgumentError);
  });
  test('merge offsets indices and rejects incompatible layouts', () {
    final plane = PlaneGeometry();
    final merged = GeometryUtils.merge([plane, plane]);
    expect(merged.vertexCount, 8);
    expect(merged.indices, [
      ...plane.indices,
      ...plane.indices.map((i) => i + 4),
    ]);
    expect(merged.uv0, [...plane.uv0!, ...plane.uv0!]);
    final noUv = BufferGeometry(
      positions: plane.positions,
      normals: plane.normals,
      indices: plane.indices,
    );
    expect(() => GeometryUtils.merge([plane, noUv]), throwsArgumentError);
  });
  test(
    'normal generation follows triangle winding without changing source',
    () {
      final plane = PlaneGeometry();
      final reversed = BufferGeometry(
        positions: plane.positions,
        normals: plane.normals,
        indices: plane.indices.reversed.toList(),
      );
      final result = GeometryUtils.computeVertexNormals(reversed);
      expect(result.normals, [
        for (var i = 0; i < 4; i++) ...[0, 0, -1],
      ]);
      expect(reversed.normals, plane.normals);
    },
  );
}
