import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_navigation/zyren_navigation.dart';

NavigationGeometry floor(
  String id, {
  double y = 0,
  double x0 = 0,
  double x1 = 6,
  double z0 = 0,
  double z1 = 6,
  double rise = 0,
}) => NavigationGeometry(
  sourceId: id,
  revision: '1',
  vertices: [
    Vec3(x0, y, z0),
    Vec3(x1, y + rise, z0),
    Vec3(x1, y + rise, z1),
    Vec3(x0, y, z1),
  ],
  triangles: [
    [0, 2, 1],
    [0, 3, 2],
  ],
);
NavigationBaker baker({
  double radius = .2,
  double step = .25,
  double slope = math.pi / 4,
}) => NavigationBaker(
  settings: NavigationBakeSettings(
    cellSize: .2,
    radius: radius,
    height: 1.8,
    maxStep: step,
    maxSlope: slope,
  ),
);
void main() {
  test(
    'bakes triangle seams into a clearance-eroded mesh with source identity',
    () {
      final mesh = baker().bake([floor('floor')]);
      expect(mesh.cells, isNotEmpty);
      expect(mesh.sources, {'floor': '1'});
      expect(mesh.locate(const Vec3(.05, 0, 3)), isNull);
      expect(mesh.locate(const Vec3(3, 0, 3)), isNotNull);
      expect(mesh.triangles.length, mesh.cells.length * 2);
      final route = NavigationWorld(
        mesh,
      ).findPath(const Vec3(.5, 0, .5), const Vec3(5.5, 0, 5.5));
      expect(route.status, RouteStatus.found);
      expect(route.points.every((p) => mesh.locate(p) != null), isTrue);
    },
  );
  test('layers retain floor identity and reject insufficient headroom', () {
    final mesh = baker().bake([floor('lower'), floor('upper', y: 3)]);
    final a = mesh.locate(const Vec3(3, 0, 3)),
        b = mesh.locate(const Vec3(3, 3, 3));
    expect(a, isNotNull);
    expect(b, isNotNull);
    expect(a, isNot(b));
    expect(
      NavigationWorld(
        mesh,
      ).findPath(const Vec3(3, 0, 3), const Vec3(3, 3, 3)).status,
      RouteStatus.disconnected,
    );
    final low = baker().bake([floor('floor'), floor('ceiling', y: 1.5)]);
    expect(low.locate(const Vec3(3, 0, 3)), isNull);
  });
  test(
    'holes and narrow passages are not filled by sampling or duplicate area',
    () {
      final pieces = [
        floor('left', x1: 2.8),
        floor('right', x0: 3.2),
        floor('back', x0: 2.8, x1: 3.2, z0: 4),
        floor('front', x0: 2.8, x1: 3.2, z1: 2),
      ];
      final mesh = baker().bake(pieces);
      expect(mesh.locate(const Vec3(3, 0, 3)), isNull);
      final route = NavigationWorld(
        mesh,
      ).findPath(const Vec3(1, 0, 3), const Vec3(5, 0, 3));
      expect(route.status, RouteStatus.found);
      expect(route.points.any((p) => p.z < 1.81 || p.z > 4.19), isTrue);
      final narrow = baker(radius: .3).bake([floor('strip', z1: .5)]);
      expect(narrow.cells, isEmpty);
      final triangle = NavigationGeometry(
        sourceId: 'duplicate',
        revision: '1',
        vertices: const [Vec3(0, 0, 0), Vec3(6, 0, 0), Vec3(0, 0, 6)],
        triangles: [
          [0, 2, 1],
          [0, 2, 1],
        ],
      );
      expect(baker().bake([triangle]).locate(const Vec3(5, 0, 5)), isNull);
    },
  );
  test('slope and step limits control connectivity', () {
    final mesh = baker().bake([
      floor('low', x1: 3),
      floor('step', x0: 3, y: .2),
    ]);
    expect(
      NavigationWorld(
        mesh,
      ).findPath(const Vec3(1, 0, 3), const Vec3(5, .2, 3)).status,
      RouteStatus.found,
    );
    final tall = baker().bake([
      floor('low', x1: 3),
      floor('tall', x0: 3, y: .5),
    ]);
    expect(
      NavigationWorld(
        tall,
      ).findPath(const Vec3(1, 0, 3), const Vec3(5, .5, 3)).status,
      RouteStatus.disconnected,
    );
    expect(baker(slope: .3).bake([floor('steep', rise: 4)]).cells, isEmpty);
    expect(baker().bake([floor('ramp', rise: 2)]).cells, isNotEmpty);
  });
  test(
    'vertical walls and scene transform snapshots block cross-wall routes',
    () {
      final wall = NavigationGeometry(
        sourceId: 'wall',
        revision: '7',
        vertices: const [
          Vec3(3, 0, 0),
          Vec3(3, 3, 0),
          Vec3(3, 3, 6),
          Vec3(3, 0, 6),
        ],
        triangles: [
          [0, 1, 2],
          [0, 2, 3],
        ],
      );
      final mesh = baker().bake([floor('floor'), wall]);
      expect(
        NavigationWorld(
          mesh,
        ).findPath(const Vec3(1, 0, 3), const Vec3(5, 0, 3)).status,
        RouteStatus.disconnected,
      );
      final object = Mesh(
        BoxGeometry(width: 6, height: .2, depth: 6),
        UnlitMaterial(),
      )..position = const Vec3(10, -.1, 0);
      final source = NavigationGeometry.fromMesh(
        object,
        sourceId: 'mesh',
        revision: 'transform:1',
      );
      object.position = Vec3.zero;
      expect(baker().bake([source]).locate(const Vec3(10, 0, 0)), isNotNull);
    },
  );
  test(
    'obstacle updates invalidate routes, replan around boxes and stop if sealed',
    () {
      final world = NavigationWorld(baker().bake([floor('floor')]));
      final follower = NavigationFollower(world)..setGoal(const Vec3(5, 0, 3));
      final start = const Vec3(1, 0, 3);
      expect(follower.intent(start, .1).length, greaterThan(0));
      final original = follower.route!;
      world.setObstacles([
        NavigationObstacle(
          'crate',
          min: const Vec3(2, 0, 2),
          max: const Vec3(4, 2, 4),
        ),
      ]);
      expect(world.isCurrent(original), isFalse);
      follower.intent(start, .1);
      expect(follower.replans, 2);
      expect(follower.route!.status, RouteStatus.found);
      expect(follower.route!.points.any((p) => p.z < 1.8 || p.z > 4.2), isTrue);
      world.setObstacles([
        NavigationObstacle(
          'barrier',
          min: const Vec3(2, 0, 0),
          max: const Vec3(4, 2, 6),
        ),
      ]);
      expect(follower.intent(start, .1), Vec3.zero);
      expect(follower.route!.status, RouteStatus.disconnected);
      world.setObstacles([]);
      expect(follower.intent(start, .1).length, greaterThan(0));
    },
  );
  test('budgets and cancellation return no partial route or bake', () {
    expect(
      () => baker().bake([floor('f')], cancelled: () => true),
      throwsA(isA<NavigationBakeCancelled>()),
    );
    expect(
      () => NavigationBaker(
        settings: NavigationBakeSettings(maxOperations: 1),
      ).bake([floor('f')]),
      throwsA(isA<NavigationBakeBudgetExceeded>()),
    );
    final world = NavigationWorld(baker().bake([floor('f')]));
    expect(
      world
          .findPath(const Vec3(1, 0, 1), const Vec3(5, 0, 5), maxVisited: 1)
          .status,
      RouteStatus.budgetExceeded,
    );
    expect(
      world
          .findPath(
            const Vec3(1, 0, 1),
            const Vec3(5, 0, 5),
            cancelled: () => true,
          )
          .status,
      RouteStatus.cancelled,
    );
  });
}
