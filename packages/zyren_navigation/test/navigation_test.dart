import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_navigation/zyren_navigation.dart';

// An L-shaped floor with a missing upper-right square.
NavigationMesh floor() => NavigationMesh(
  vertices: const [
    Vec3(0, 0, 0),
    Vec3(1, 0, 0),
    Vec3(2, 0, 0),
    Vec3(0, 0, 1),
    Vec3(1, 0, 1),
    Vec3(2, 0, 1),
    Vec3(0, 0, 2),
    Vec3(1, 0, 2),
  ],
  triangles: const [
    [0, 1, 4],
    [0, 4, 3],
    [1, 2, 5],
    [1, 5, 4],
    [3, 4, 7],
    [3, 7, 6],
  ],
);

void main() {
  test(
    'L corridor goes around the missing square and samples remain inside',
    () {
      final mesh = floor();
      const start = Vec3(1.8, 0, .2), goal = Vec3(.2, 0, 1.8);
      final path = mesh.findPath(start, goal);
      expect(path.status, NavigationStatus.found);
      expect(path.points.first, start);
      expect(path.points.last, goal);
      expect(path.triangles, [2, 3, 0, 1, 4, 5]);
      expect(path.length, closeTo(2.848528137423857, 1e-9));
      for (var i = 0; i <= 1000; i++) {
        expect(mesh.locate(path.pointAt(path.length * i / 1000)), isNotNull);
      }
      expect(path.pointAt(100), goal);
      expect(mesh.findPath(start, goal).points, path.points);
      expect(() => path.points.clear(), throwsUnsupportedError);
    },
  );
  test('same triangle, zero length and boundary ties are deterministic', () {
    final mesh = floor();
    const point = Vec3(.2, 0, .1);
    final path = mesh.findPath(point, point);
    expect(path.triangles, [0]);
    expect(path.length, 0);
    expect(path.pointAt(0), point);
    expect(mesh.locate(const Vec3(.5, 0, .5)), 0);
    expect(() => path.pointAt(double.nan), throwsArgumentError);
    expect(() => path.pointAt(-1), throwsArgumentError);
  });
  test('outside, elevation and budget failures do not masquerade as paths', () {
    final mesh = floor();
    const a = Vec3(1.8, 0, .2), b = Vec3(.2, 0, 1.8);
    expect(
      mesh.findPath(const Vec3(3, 0, 3), b).status,
      NavigationStatus.startOutside,
    );
    expect(
      mesh.findPath(a, const Vec3(.2, 1, .2)).status,
      NavigationStatus.goalOutside,
    );
    final limited = mesh.findPath(a, b, maxVisited: 1);
    expect(limited.status, NavigationStatus.budgetExceeded);
    expect(limited.visited, 1);
    expect(limited.points, isEmpty);
    expect(() => limited.pointAt(0), throwsStateError);
    expect(() => mesh.findPath(a, b, maxVisited: 0), throwsArgumentError);
    expect(() => mesh.findPath(a, Vec3(double.nan, 0, 0)), throwsArgumentError);
  });
  test('disconnected islands return an explicit failure', () {
    final mesh = NavigationMesh(
      vertices: const [
        Vec3(0, 0, 0),
        Vec3(1, 0, 0),
        Vec3(0, 0, 1),
        Vec3(3, 0, 0),
        Vec3(4, 0, 0),
        Vec3(3, 0, 1),
      ],
      triangles: const [
        [0, 1, 2],
        [3, 4, 5],
      ],
    );
    expect(
      mesh.findPath(const Vec3(.1, 0, .1), const Vec3(3.1, 0, .1)).status,
      NavigationStatus.disconnected,
    );
  });
  test('construction snapshots inputs and normalizes triangle winding', () {
    final vertices = [
      const Vec3(0, 2, 0),
      const Vec3(1, 2, 0),
      const Vec3(0, 2, 1),
    ];
    final triangle = [0, 2, 1];
    final mesh = NavigationMesh(vertices: vertices, triangles: [triangle]);
    vertices.clear();
    triangle.clear();
    expect(mesh.locate(const Vec3(.1, 2, .1)), 0);
    expect(mesh.triangles.single, [0, 1, 2]);
  });
  test('invalid topology and geometry are rejected before querying', () {
    void invalid(List<Vec3> vs, List<List<int>> ts) => expect(
      () => NavigationMesh(vertices: vs, triangles: ts),
      throwsArgumentError,
    );
    const square = [Vec3(0, 0, 0), Vec3(1, 0, 0), Vec3(1, 0, 1), Vec3(0, 0, 1)];
    invalid(square, [
      [0, 1, 4],
    ]);
    invalid(square, [
      [0, 1, 1],
    ]);
    invalid(square, [
      [0, 1, 2],
      [2, 1, 0],
    ]);
    invalid(square, [
      [0, 1, 2],
      [0, 1, 3],
    ]);
    invalid(
      [...square, const Vec3(.5, 0, .5)],
      [
        [0, 1, 2],
        [0, 2, 3],
      ],
    );
    invalid(
      [...square, const Vec3(0, 0, 0)],
      [
        [0, 1, 2],
      ],
    );
    invalid(
      [const Vec3(0, 0, 0), const Vec3(1, 1, 0), const Vec3(0, 0, 1)],
      [
        [0, 1, 2],
      ],
    );
    invalid(
      [const Vec3(0, 0, 0), const Vec3(1, 0, 0), const Vec3(2, 0, 0)],
      [
        [0, 1, 2],
      ],
    );
    invalid(
      [Vec3(double.infinity, 0, 0), ...square],
      [
        [0, 1, 2],
      ],
    );
    invalid(square, List.filled(1025, [0, 1, 2]));
    invalid(square, [
      [0, 1, 2],
      [0, 1, 3],
      [1, 0, 2],
    ]);
  });
}
