import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'navigation_bake.dart';

enum RouteStatus {
  found,
  startOutside,
  goalOutside,
  blocked,
  disconnected,
  budgetExceeded,
  cancelled,
}

final class NavigationObstacle {
  final String id;
  final Vec3 min, max;
  NavigationObstacle(this.id, {required this.min, required this.max}) {
    if (id.trim().isEmpty ||
        !min.isFinite ||
        !max.isFinite ||
        min.x > max.x ||
        min.y > max.y ||
        min.z > max.z) {
      throw ArgumentError('Invalid obstacle bounds.');
    }
  }
}

final class NavigationRoute {
  final Object _owner;
  final RouteStatus status;
  final int revision, visited;
  final List<int> cells;
  final List<Vec3> points;
  NavigationRoute._(
    this._owner,
    this.status,
    this.revision,
    this.visited,
    Iterable<int> cells,
    Iterable<Vec3> points,
  ) : cells = List.unmodifiable(cells),
      points = List.unmodifiable(points);
  double get length {
    var value = 0.0;
    for (var i = 1; i < points.length; i++) {
      value += points[i - 1].distanceTo(points[i]);
    }
    return value;
  }
}

/// Versioned bake and obstacle state. Updates replace snapshots atomically.
final class NavigationWorld {
  BakedNavigationMesh _mesh;
  Map<String, NavigationObstacle> _obstacles = {};
  Set<int> _blocked = {};
  int _revision = 0;
  NavigationWorld(this._mesh);
  BakedNavigationMesh get mesh => _mesh;
  int get revision => _revision;
  Map<String, NavigationObstacle> get obstacles => Map.unmodifiable(_obstacles);
  Set<int> get blockedCells => Set.unmodifiable(_blocked);
  void replaceMesh(BakedNavigationMesh mesh) {
    final blocked = _blocking(mesh, _obstacles.values);
    _mesh = mesh;
    _blocked = blocked;
    _revision++;
  }

  void setObstacles(Iterable<NavigationObstacle> obstacles) {
    final list = obstacles.toList();
    if (list.length > 256 ||
        list.map((o) => o.id).toSet().length != list.length) {
      throw ArgumentError('Use at most 256 unique obstacles.');
    }
    final blocked = _blocking(_mesh, list);
    _obstacles = {for (final o in list) o.id: o};
    _blocked = blocked;
    _revision++;
  }

  Set<int> _blocking(
    BakedNavigationMesh mesh,
    Iterable<NavigationObstacle> obstacles,
  ) {
    final margin = mesh.settings.radius + mesh.settings.cellSize / 2;
    return {
      for (final c in mesh.cells)
        if (obstacles.any(
          (o) =>
              c.center.x >= o.min.x - margin &&
              c.center.x <= o.max.x + margin &&
              c.center.z >= o.min.z - margin &&
              c.center.z <= o.max.z + margin &&
              c.corners.map((p) => p.y).reduce(math.min) +
                      mesh.settings.height >
                  o.min.y &&
              c.corners.map((p) => p.y).reduce(math.max) < o.max.y,
        ))
          c.id,
    };
  }

  bool isCurrent(NavigationRoute route) =>
      identical(route._owner, this) && route.revision == revision;
  NavigationRoute findPath(
    Vec3 start,
    Vec3 goal, {
    int maxVisited = 4096,
    bool Function()? cancelled,
  }) {
    if (maxVisited < 1 || maxVisited > 65536) {
      throw ArgumentError('Query budget must fit [1,65536].');
    }
    final revision = this.revision, mesh = _mesh, blocked = _blocked;
    NavigationRoute failed(RouteStatus status, int visited) =>
        NavigationRoute._(this, status, revision, visited, [], []);
    if (cancelled?.call() == true) return failed(RouteStatus.cancelled, 0);
    final from = mesh.locate(start), to = mesh.locate(goal);
    if (from == null) return failed(RouteStatus.startOutside, 0);
    if (to == null) return failed(RouteStatus.goalOutside, 0);
    if (blocked.contains(from) || blocked.contains(to)) {
      return failed(RouteStatus.blocked, 0);
    }
    final open = <int>{from},
        closed = <int>{},
        cost = <int, double>{from: 0},
        parent = <int, int>{};
    while (open.isNotEmpty) {
      if (cancelled?.call() == true) {
        return failed(RouteStatus.cancelled, closed.length);
      }
      if (closed.length >= maxVisited) {
        return failed(RouteStatus.budgetExceeded, closed.length);
      }
      final current = open.reduce((a, b) {
        final ac =
                cost[a]! +
                mesh.cells[a].center.distanceTo(mesh.cells[to].center),
            bc =
                cost[b]! +
                mesh.cells[b].center.distanceTo(mesh.cells[to].center);
        return ac < bc || ac == bc && a < b ? a : b;
      });
      open.remove(current);
      closed.add(current);
      if (current == to) {
        final cells = [current];
        while (parent.containsKey(cells.last)) {
          cells.add(parent[cells.last]!);
        }
        final ordered = cells.reversed.toList();
        return NavigationRoute._(
          this,
          RouteStatus.found,
          revision,
          closed.length,
          ordered,
          [start, ...ordered.map((id) => mesh.cells[id].center), goal],
        );
      }
      for (final next in mesh.neighbors[current]) {
        if (closed.contains(next) || blocked.contains(next)) continue;
        final nextCost =
            cost[current]! +
            mesh.cells[current].center.distanceTo(mesh.cells[next].center);
        if (nextCost < (cost[next] ?? double.infinity)) {
          cost[next] = nextCost;
          parent[next] = current;
          open.add(next);
        }
      }
    }
    return failed(RouteStatus.disconnected, closed.length);
  }
}

/// Reads actual position each step. A failed or stale query produces no motion.
/// Submit the returned intent to a collision controller before applying it.
final class NavigationFollower {
  final NavigationWorld world;
  final int maxVisited;
  Vec3? _goal;
  NavigationRoute? _route;
  int _waypoint = 0, replans = 0;
  NavigationFollower(this.world, {this.maxVisited = 4096});
  Vec3? get goal => _goal;
  NavigationRoute? get route => _route;
  void setGoal(Vec3? goal) {
    if (goal != null && !goal.isFinite) {
      throw ArgumentError('Goal must be finite.');
    }
    _goal = goal;
    _route = null;
    _waypoint = 0;
  }

  Vec3 intent(Vec3 position, double distance, {bool Function()? cancelled}) {
    if (!position.isFinite || !distance.isFinite || distance < 0) {
      throw ArgumentError('Invalid movement query.');
    }
    final goal = _goal;
    if (goal == null || distance == 0 || cancelled?.call() == true) {
      return Vec3.zero;
    }
    if (_route == null || !world.isCurrent(_route!)) {
      _route = world.findPath(
        position,
        goal,
        maxVisited: maxVisited,
        cancelled: cancelled,
      );
      _waypoint = 1;
      replans++;
    }
    final route = _route!;
    if (route.status != RouteStatus.found) return Vec3.zero;
    final cell = world.mesh.locate(
      position,
      tolerance: world.mesh.settings.maxStep + .06,
    );
    if (cell == null || !route.cells.contains(cell)) {
      _route = null;
      return Vec3.zero;
    }
    while (_waypoint < route.points.length &&
        position.distanceTo(route.points[_waypoint]) < .01) {
      _waypoint++;
    }
    if (_waypoint >= route.points.length) return Vec3.zero;
    final delta = route.points[_waypoint] - position;
    return delta.length <= distance ? delta : delta.normalized() * distance;
  }
}
