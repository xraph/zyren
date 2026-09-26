import 'dart:math' as math;

/// Immutable indexed triangle geometry. Positions are local to the mesh.
class BufferGeometry {
  static int _nextId = 1;
  final int id = _nextId++;
  final List<double> positions;
  final List<double> normals;
  final List<int> indices;

  BufferGeometry({
    required List<double> positions,
    required List<double> normals,
    required List<int> indices,
  }) : positions = List.unmodifiable(positions),
       normals = List.unmodifiable(normals),
       indices = List.unmodifiable(indices) {
    if (positions.isEmpty ||
        positions.length % 3 != 0 ||
        positions.length != normals.length ||
        indices.isEmpty ||
        indices.length % 3 != 0 ||
        positions.any((v) => !v.isFinite) ||
        normals.any((v) => !v.isFinite) ||
        indices.any((i) => i < 0 || i >= positions.length ~/ 3)) {
      throw ArgumentError(
        'Geometry requires finite positions, matching normals and valid triangle indices.',
      );
    }
    for (var i = 0; i < normals.length; i += 3) {
      if (normals[i] * normals[i] +
              normals[i + 1] * normals[i + 1] +
              normals[i + 2] * normals[i + 2] <
          1e-12) {
        throw ArgumentError('Vertex normals must be nonzero.');
      }
    }
  }

  Map<String, Object> toNative() => {
    'id': id,
    'positions': [
      for (var i = 0; i < positions.length; i += 3) positions.sublist(i, i + 3),
    ],
    'normals': [
      for (var i = 0; i < normals.length; i += 3) normals.sublist(i, i + 3),
    ],
    'indices': indices,
  };
}

class BoxGeometry extends BufferGeometry {
  factory BoxGeometry({double width = 1, double height = 1, double depth = 1}) {
    if ([width, height, depth].any((v) => !v.isFinite || v <= 0)) {
      throw ArgumentError('Box dimensions must be finite and positive.');
    }
    final p = <double>[], n = <double>[];
    final indices = <int>[];
    final corners = [
      [1.0, -1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, 1.0, 1.0, -1.0, 1.0],
      [-1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0, 1.0, -1.0, -1.0, -1.0, -1.0],
      [-1.0, 1.0, -1.0, -1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, -1.0],
      [-1.0, -1.0, 1.0, -1.0, -1.0, -1.0, 1.0, -1.0, -1.0, 1.0, -1.0, 1.0],
      [-1.0, -1.0, 1.0, 1.0, -1.0, 1.0, 1.0, 1.0, 1.0, -1.0, 1.0, 1.0],
      [1.0, -1.0, -1.0, -1.0, -1.0, -1.0, -1.0, 1.0, -1.0, 1.0, 1.0, -1.0],
    ];
    final faceNormals = [
      [1.0, 0.0, 0.0],
      [-1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
      [0.0, -1.0, 0.0],
      [0.0, 0.0, 1.0],
      [0.0, 0.0, -1.0],
    ];
    for (var f = 0; f < 6; f++) {
      for (var i = 0; i < 12; i += 3) {
        p.addAll([
          corners[f][i] * width / 2,
          corners[f][i + 1] * height / 2,
          corners[f][i + 2] * depth / 2,
        ]);
        n.addAll(faceNormals[f]);
      }
      final o = f * 4;
      indices.addAll([o, o + 1, o + 2, o, o + 2, o + 3]);
    }
    return BoxGeometry._(p, n, indices);
  }
  BoxGeometry._(List<double> p, List<double> n, List<int> i)
    : super(positions: p, normals: n, indices: i);
}

/// Y-up sphere. Use EllipsoidGeometry for an ECEF globe.
class SphereGeometry extends BufferGeometry {
  factory SphereGeometry({
    double radius = 1,
    int widthSegments = 64,
    int heightSegments = 32,
  }) {
    if (!radius.isFinite ||
        radius <= 0 ||
        widthSegments < 3 ||
        heightSegments < 2 ||
        (widthSegments + 1) * (heightSegments + 1) > 1000000) {
      throw ArgumentError('Invalid sphere radius or segment count.');
    }
    final p = <double>[], n = <double>[];
    final indices = <int>[];
    for (var y = 0; y <= heightSegments; y++) {
      final phi = math.pi * y / heightSegments;
      for (var x = 0; x <= widthSegments; x++) {
        final theta = 2 * math.pi * x / widthSegments;
        final normal = [
          math.sin(phi) * math.cos(theta),
          math.cos(phi),
          math.sin(phi) * math.sin(theta),
        ];
        n.addAll(normal);
        p.addAll(normal.map((v) => v * radius));
      }
    }
    for (var y = 0; y < heightSegments; y++) {
      for (var x = 0; x < widthSegments; x++) {
        final a = y * (widthSegments + 1) + x, b = a + widthSegments + 1;
        if (y > 0) indices.addAll([a, a + 1, b]);
        if (y < heightSegments - 1) indices.addAll([a + 1, b + 1, b]);
      }
    }
    return SphereGeometry._(p, n, indices);
  }
  SphereGeometry._(List<double> p, List<double> n, List<int> i)
    : super(positions: p, normals: n, indices: i);
}
