import 'package:zyren/zyren.dart';

BufferGeometry combineCapShells(List<(BufferGeometry, Vec3)> shells) {
  final positions = <double>[], normals = <double>[], indices = <int>[];
  for (final shell in shells) {
    final offset = positions.length ~/ 3;
    for (var i = 0; i < shell.$1.positions.length; i += 3) {
      positions.addAll((Vec3.array(shell.$1.positions, i) + shell.$2).storage);
      normals.addAll(Vec3.array(shell.$1.normals, i).storage);
    }
    indices.addAll(shell.$1.indices.map((i) => i + offset));
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: indices,
  );
}

BufferGeometry concaveCapPrism() {
  const polygon = [
    (0.0, 0.0),
    (2.0, 0.0),
    (2.0, 1.0),
    (1.0, 1.0),
    (1.0, 2.0),
    (0.0, 2.0),
  ];
  final positions = <double>[], indices = <int>[];
  for (final z in [-1.0, 1.0]) {
    for (final p in polygon) {
      positions.addAll([p.$1, p.$2, z]);
    }
  }
  for (final t in [
    [0, 1, 3],
    [1, 2, 3],
    [0, 3, 5],
    [3, 4, 5],
  ]) {
    indices.addAll([t[0], t[2], t[1], t[0] + 6, t[1] + 6, t[2] + 6]);
  }
  for (var i = 0; i < 6; i++) {
    final j = (i + 1) % 6;
    indices.addAll([i, j, j + 6, i, j + 6, i + 6]);
  }
  return BufferGeometry(
    positions: positions,
    normals: [
      for (var i = 0; i < positions.length ~/ 3; i++) ...[0.0, 0.0, 1.0],
    ],
    indices: indices,
  );
}

double capArea(BufferGeometry geometry) {
  var area = 0.0;
  for (var i = 0; i < geometry.indices.length; i += 3) {
    final a = Vec3.array(geometry.positions, geometry.indices[i] * 3);
    final b = Vec3.array(geometry.positions, geometry.indices[i + 1] * 3);
    final c = Vec3.array(geometry.positions, geometry.indices[i + 2] * 3);
    area += (b - a).cross(c - a).length / 2;
  }
  return area;
}
