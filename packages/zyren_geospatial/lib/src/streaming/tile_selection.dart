import 'package:zyren/zyren.dart';
import '../tiling.dart';
import 'tile_source.dart';

final class TileSelection {
  final nodes = <TileCoordinate, TileMetadata>{};
  final branches = <TileCoordinate, List<TileCoordinate>>{};
  final roots = <TileCoordinate>[];
  bool budgetLimited = false;
}

TileSelection selectTiles(
  TileSource source,
  Camera camera,
  ViewportMetrics viewport,
  TileBudget budget,
  double maximumError,
  Set<TileCoordinate> previouslyRefined,
) {
  final result = TileSelection();
  var decoded = 0, resident = 0;
  bool admit(List<TileMetadata> group) {
    final cpu = group.fold(0, (sum, n) => sum + n.decodedBytes);
    final gpu = group.fold(0, (sum, n) => sum + n.residentBytes);
    if (decoded + cpu > budget.maxDecodedBytes ||
        resident + gpu > budget.maxResidentBytes ||
        result.nodes.length + group.length > budget.maxSelectedTiles) {
      result.budgetLimited = true;
      return false;
    }
    decoded += cpu;
    resident += gpu;
    for (final node in group) {
      result.nodes[node.coordinate] = node;
    }
    return true;
  }

  TileMetadata describe(TileCoordinate tile) {
    final node = source.describe(tile);
    if (node.coordinate != tile) {
      throw StateError('Source returned metadata for another tile.');
    }
    return node;
  }

  // Bound even malformed/infinite root iterables before materializing them.
  final roots = source.roots.take(budget.maxSelectedTiles + 1).toList();
  if (roots.length > budget.maxSelectedTiles ||
      roots.toSet().length != roots.length ||
      roots.any((r) => r.z != 0)) {
    throw StateError('Source roots exceed the tile budget or are invalid.');
  }
  final visibleRoots = roots
      .map(describe)
      .where((n) => n.isVisible(camera, viewport))
      .toList();
  if (!admit(visibleRoots)) return result;
  result.roots.addAll(visibleRoots.map((n) => n.coordinate));
  final queue = [...visibleRoots];
  while (queue.isNotEmpty) {
    // Largest projected error first, then deterministic coordinate order.
    queue.sort((a, b) {
      final error = b
          .screenError(camera, viewport)
          .compareTo(a.screenError(camera, viewport));
      if (error != 0) return error;
      final z = a.coordinate.z.compareTo(b.coordinate.z);
      if (z != 0) return z;
      final y = a.coordinate.y.compareTo(b.coordinate.y);
      return y != 0 ? y : a.coordinate.x.compareTo(b.coordinate.x);
    });
    final node = queue.removeAt(0);
    final threshold =
        maximumError * (previouslyRefined.contains(node.coordinate) ? .8 : 1);
    if (node.children.isEmpty ||
        node.screenError(camera, viewport) <= threshold) {
      continue;
    }
    final children = node.children
        .map(describe)
        .where((n) => n.isVisible(camera, viewport))
        .toList();
    if (children.isEmpty || !admit(children)) continue;
    result.branches[node.coordinate] = children
        .map((n) => n.coordinate)
        .toList();
    queue.addAll(children);
  }
  return result;
}
