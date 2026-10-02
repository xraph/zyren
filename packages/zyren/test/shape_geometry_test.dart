import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

List<Vec2> square(double lo, double hi) => [
  Vec2(lo, lo),
  Vec2(hi, lo),
  Vec2(hi, hi),
  Vec2(lo, hi),
];
double area(BufferGeometry geometry) {
  var sum = 0.0;
  for (var i = 0; i < geometry.indices.length; i += 3) {
    final a = Vec3.array(geometry.positions, geometry.indices[i] * 3);
    final b = Vec3.array(geometry.positions, geometry.indices[i + 1] * 3);
    final c = Vec3.array(geometry.positions, geometry.indices[i + 2] * 3);
    sum += (b - a).cross(c - a).length / 2;
  }
  return sum;
}

void closedVolume(BufferGeometry geometry) {
  final edges = <String, int>{};
  var volume = 0.0;
  String key(Vec3 p) => p.storage.map((v) => (v * 1e6).round()).join(',');
  for (var i = 0; i < geometry.indices.length; i += 3) {
    final points = [
      for (var j = 0; j < 3; j++)
        Vec3.array(geometry.positions, geometry.indices[i + j] * 3),
    ];
    volume += points[0].dot(points[1].cross(points[2])) / 6;
    final normal = (points[1] - points[0])
        .cross(points[2] - points[0])
        .normalized();
    expect(
      normal.dot(Vec3.array(geometry.normals, geometry.indices[i] * 3)),
      greaterThan(.999),
    );
    for (var j = 0; j < 3; j++) {
      final pair = [key(points[j]), key(points[(j + 1) % 3])]..sort();
      edges.update(pair.join('/'), (n) => n + 1, ifAbsent: () => 1);
    }
  }
  expect(volume, greaterThan(0));
  expect(edges.values.every((count) => count == 2), isTrue);
}

void main() {
  test('concave polygons and holes triangulate with canonical winding', () {
    final outer = square(-2, 2);
    final hole = square(-1, 1);
    final shape = Shape2D(outer.reversed.toList(), holes: [hole]);
    outer[0] = Vec2.zero;
    hole.clear();
    final geometry = ShapeGeometry(shape, indexFormat: IndexFormat.uint16);
    expect(area(geometry), closeTo(12, 1e-6));
    expect(geometry.normals.every((v) => v == 0 || v == 1), isTrue);
    final scene = Scene()..add(Mesh(geometry, UnlitMaterial()));
    final raycaster = Raycaster();
    expect(
      raycaster
          .capture(scene, Ray(const Vec3(0, 0, 2), const Vec3(0, 0, -1)))
          .intersectAll(),
      isEmpty,
    );
    final concave = ShapeGeometry(
      Shape2D(const [
        Vec2(0, 0),
        Vec2(3, 0),
        Vec2(3, 1),
        Vec2(1, 1),
        Vec2(1, 3),
        Vec2(0, 3),
      ]),
    );
    expect(area(concave), closeTo(5, 1e-6));
  });
  test('beveled extrusion keeps hole walls, caps and positive volume', () {
    final shape = Shape2D(square(-2, 2), holes: [square(-.5, .5)]);
    final geometry = ExtrudeGeometry(
      shape,
      depth: 2,
      bevelSize: .15,
      bevelThickness: .25,
      bevelSegments: 3,
    );
    expect(geometry.positions.every((v) => v.isFinite), isTrue);
    expect(geometry.normals.any((v) => v.abs() > 0 && v.abs() < .99), isTrue);
    expect(area(geometry), greaterThan(40));
    closedVolume(geometry);
    expect(
      () => ExtrudeGeometry(shape, depth: .2, bevelSize: .2),
      throwsArgumentError,
    );
    expect(() => ExtrudeGeometry(shape, bevelSize: 2), throwsArgumentError);
  });
  test('invalid rings fail before triangulation', () {
    expect(
      () => Shape2D(const [Vec2(0, 0), Vec2(2, 2), Vec2(0, 2), Vec2(2, 0)]),
      throwsArgumentError,
    );
    expect(
      () => Shape2D(square(-2, 2), holes: [square(1, 3)]),
      throwsArgumentError,
    );
    expect(
      () => Shape2D(square(-2, 2), holes: [square(-1, 1), square(-.5, .5)]),
      throwsArgumentError,
    );
    expect(
      () => Shape2D(square(-2, 2), holes: [square(-2, 0)]),
      throwsArgumentError,
    );
    expect(() => Shape2D(List.filled(4097, Vec2.zero)), throwsArgumentError);
  });
  test('extrusion caps and inner walls form an outward closed volume', () {
    final shape = Shape2D(square(-2, 2), holes: [square(-1, 1)]);
    final geometry = ExtrudeGeometry(shape, depth: 3, steps: 2);
    expect(area(geometry), closeTo(96, 1e-5));
    var volume = 0.0;
    for (var i = 0; i < geometry.indices.length; i += 3) {
      final a = Vec3.array(geometry.positions, geometry.indices[i] * 3);
      final b = Vec3.array(geometry.positions, geometry.indices[i + 1] * 3);
      final c = Vec3.array(geometry.positions, geometry.indices[i + 2] * 3);
      volume += a.dot(b.cross(c)) / 6;
    }
    expect(volume, closeTo(36, 1e-5));
    expect(() => ExtrudeGeometry(shape, depth: 0), throwsArgumentError);
    expect(() => ExtrudeGeometry(shape, steps: 1000000), throwsArgumentError);
    expect(geometry.uv0!.every((v) => v.isFinite), isTrue);
  });
}
