import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_navigation/zyren_navigation.dart';

NavigationWorld world() => NavigationWorld(
  NavigationBaker(
    settings: NavigationBakeSettings(cellSize: .2, radius: .1),
  ).bake([
    NavigationGeometry(
      sourceId: 'floor',
      revision: '1',
      vertices: const [
        Vec3(0, 0, 0),
        Vec3(6, 0, 0),
        Vec3(6, 0, 6),
        Vec3(0, 0, 6),
      ],
      triangles: const [
        [0, 2, 1],
        [0, 3, 2],
      ],
    ),
  ]),
);
void main() {
  test('optional follower bounds reject invalid tolerance and look-ahead', () {
    for (final tolerance in [0.0, -.1, .51, double.nan]) {
      expect(
        () => NavigationFollower(world(), reachTolerance: tolerance),
        throwsArgumentError,
      );
    }
    for (final ahead in [-.1, 2.01, double.infinity]) {
      expect(
        () => NavigationFollower(world(), lookAhead: ahead),
        throwsArgumentError,
      );
    }
    expect(NavigationFollower(world()).reachTolerance, .01);
    expect(NavigationFollower(world()).lookAhead, 0);
  });
  test(
    'look-ahead stays on straight route and cannot skip a published corner',
    () {
      final w = world()
        ..setObstacles([
          NavigationObstacle(
            'strip',
            min: const Vec3(2, 0, 1),
            max: const Vec3(3, 2, 4),
          ),
        ]);
      final f = NavigationFollower(w, reachTolerance: .5, lookAhead: 2)
        ..setGoal(const Vec3(4.5, 0, 2.5));
      var at = const Vec3(1.5, 0, 2.5);
      for (var i = 0; i < 1000; i++) {
        final delta = f.intent(at, .02);
        at = at + delta;
        final cell = w.mesh.locate(at);
        expect(cell, isNotNull);
        expect(w.blockedCells.contains(cell), false);
        if ((at - const Vec3(4.5, 0, 2.5)).length < .5) break;
      }
      expect((at - const Vec3(4.5, 0, 2.5)).length, lessThan(.51));
    },
  );
}
