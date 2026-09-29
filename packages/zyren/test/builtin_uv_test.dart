import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

void main() {
  test('box UVs cover each face with world Y upright on side faces', () {
    final box = BoxGeometry(width: 2, height: 4, depth: 6, dynamic: true);
    expect(box.uv0, isNotNull);
    expect(box.uv0, hasLength(48));
    expect(box.vertexCount, 24);
    expect(box.indices, hasLength(36));
    for (var face = 0; face < 6; face++) {
      final uv = box.uv0!.sublist(face * 8, face * 8 + 8);
      expect(
        {for (var i = 0; i < 8; i += 2) (uv[i], uv[i + 1])},
        {(0.0, 0.0), (1.0, 0.0), (0.0, 1.0), (1.0, 1.0)},
      );
      if ([0, 1, 4, 5].contains(face)) {
        for (var vertex = 0; vertex < 4; vertex++) {
          expect(
            uv[vertex * 2 + 1],
            box.positions[(face * 4 + vertex) * 3 + 1] > 0 ? 0 : 1,
          );
        }
      }
    }
    final before = box.capture();
    box.updateAttribute(VertexSemantic.uv0, Float32List.fromList([.25, .75]));
    expect(before.uv0!.first, 1);
    expect(box.uv0!.first, .25);
  });
  test('sphere UVs duplicate the seam and center each polar triangle', () {
    const width = 12, height = 6;
    final sphere = SphereGeometry(widthSegments: width, heightSegments: height);
    expect(sphere.uv0, isNotNull);
    for (var row = 1; row < height; row++) {
      final first = row * (width + 1), last = first + width;
      expect(
        sphere.positions.sublist(first * 3, first * 3 + 3),
        sphere.positions.sublist(last * 3, last * 3 + 3),
      );
      expect(sphere.uv0![first * 2], 0);
      expect(sphere.uv0![last * 2], 1);
      expect(sphere.uv0![first * 2 + 1], closeTo(row / height, 1e-6));
    }
    for (var i = 0; i < sphere.indices.length; i += 3) {
      final triangle = sphere.indices.sublist(i, i + 3);
      final pole = triangle.where(
        (v) => v < width + 1 || v >= height * (width + 1),
      );
      if (pole.isEmpty) continue;
      final vertex = pole.single;
      final others = triangle.where((v) => v != vertex).toList();
      expect(sphere.positions[vertex * 3], 0);
      expect(sphere.positions[vertex * 3 + 2], 0);
      expect(
        sphere.uv0![vertex * 2],
        closeTo(
          (sphere.uv0![others[0] * 2] + sphere.uv0![others[1] * 2]) / 2,
          1e-6,
        ),
      );
    }
    expect(sphere.uv0!.every((v) => v >= 0 && v <= 1), isTrue);
  });
}
