import 'dart:isolate';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

GeometryData triangle() => GeometryData(
  attributes: {
    VertexSemantic.position: VertexAttribute(
      Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.normal: VertexAttribute(
      Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
      format: VertexFormat.float32x3,
    ),
  },
  indices: [0, 1, 2],
  indexFormat: IndexFormat.uint16,
);

void main() {
  test(
    'worker geometry data receives caller-local resource identities',
    () async {
      final before = BufferGeometry.fromData(triangle());
      final recipe = await Isolate.run(triangle);
      final first = BufferGeometry.fromData(recipe, dynamic: true);
      final second = BufferGeometry.fromData(recipe);
      expect({before.id, first.id, second.id}, hasLength(3));
      expect(
        first.positions,
        same(recipe.attributes[VertexSemantic.position]!.data),
      );
      expect(first.indices, same(recipe.indices));
      expect(first.capture().layout, same(recipe.layout));
      expect(first.indexFormat, IndexFormat.uint16);
      expect(recipe.byteLength, 78);
      first.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([2, 0, 0]),
      );
      expect(first.positions[0], 2);
      expect(second.positions[0], 0);
      expect(
        recipe.attributes[VertexSemantic.position]!.data,
        same(second.positions),
      );
      expect(() => recipe.indices[0] = 2, throwsUnsupportedError);
      expect(() => recipe.attributes.clear(), throwsUnsupportedError);
    },
  );
  test(
    'prepared data owns input and enforces the regular geometry contract',
    () {
      final attributes = Map.of(triangle().attributes);
      final indices = [0, 1, 2];
      final data = GeometryData(attributes: attributes, indices: indices);
      indices[0] = 2;
      attributes.clear();
      expect(data.indices, [0, 1, 2]);
      expect(data.attributes, hasLength(2));
      expect(
        () => GeometryData(attributes: data.attributes, indices: [0, 1, 3]),
        throwsArgumentError,
      );
      expect(
        () => GeometryData(attributes: data.attributes, indices: [0, 1]),
        throwsArgumentError,
      );
      expect(
        () => GeometryData(attributes: const {}, indices: [0, 1, 2]),
        throwsArgumentError,
      );
    },
  );
}
