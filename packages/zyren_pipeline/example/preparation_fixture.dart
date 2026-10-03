import 'dart:typed_data';
import 'package:zyren/zyren.dart';

BufferGeometry grid({int cells = 16, bool deform = false}) {
  final positions = <double>[], normals = <double>[], uv = <double>[];
  final indices = <int>[];
  for (var y = 0; y <= cells; y++) {
    for (var x = 0; x <= cells; x++) {
      positions.addAll([x / cells * 2 - 1, y / cells * 2 - 1, 0]);
      normals.addAll([0, 0, 1]);
      uv.addAll([x / cells, y / cells]);
    }
  }
  // Reverse alternate rows to give the cache optimizer useful work.
  for (var y = 0; y < cells; y++) {
    for (var column = 0; column < cells; column++) {
      final x = y.isEven ? column : cells - 1 - column;
      final a = y * (cells + 1) + x, b = a + 1, c = a + cells + 1, d = c + 1;
      indices.addAll([a, b, c, b, d, c]);
    }
  }
  final count = positions.length ~/ 3;
  return BufferGeometry.fromAttributes(
    attributes: {
      VertexSemantic.position: VertexAttribute(
        Float32List.fromList(positions),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.normal: VertexAttribute(
        Float32List.fromList(normals),
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.uv0: VertexAttribute(
        Float32List.fromList(uv),
        format: VertexFormat.float32x2,
      ),
      if (deform)
        VertexSemantic.joints: VertexAttribute(
          Uint16List(count * 4),
          format: VertexFormat.uint16x4,
        ),
      if (deform)
        VertexSemantic.weights: VertexAttribute(
          Float32List.fromList([
            for (var i = 0; i < count; i++) ...[1, 0, 0, 0],
          ]),
          format: VertexFormat.float32x4,
        ),
    },
    indices: indices,
    morphTargets: deform
        ? [MorphTarget(positions: List.filled(count * 3, .1))]
        : [],
  );
}

Uint8List checkerPixels() => Uint8List.fromList([
  for (var y = 0; y < 16; y++)
    for (var x = 0; x < 16; x++) ...[
      x < 8 ? 255 : 0,
      x < 8 ? 0 : 255,
      32,
      y < 8 ? 0 : 255,
    ],
]);
