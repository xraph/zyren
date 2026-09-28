import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import '../tiling.dart';

/// CPU data only. A source must not allocate native resources while loading.
abstract interface class TileContent {
  int get decodedBytes;
  int get residentBytes;
}

abstract interface class TileSource<T extends TileContent> {
  /// Include the dataset version. Credentials belong to the source adapter.
  String get identity;
  Iterable<TileCoordinate> get roots;
  TileMetadata describe(TileCoordinate coordinate);
  Future<T> load(TileCoordinate coordinate, TileLoadContext context);
}

final class TileLoadContext {
  final String sourceIdentity;
  final LoadCancellation cancellation;
  final int byteBudget;
  const TileLoadContext({
    required this.sourceIdentity,
    required this.cancellation,
    required this.byteBudget,
  });
}

/// Conservative bounds and payload limits available before starting a request.
final class TileMetadata {
  final TileCoordinate coordinate;
  final Vec3 center;
  final double radius, geometricError;
  final int decodedBytes, residentBytes;
  final List<TileCoordinate> children;
  TileMetadata({
    required this.coordinate,
    required this.center,
    required this.radius,
    required this.geometricError,
    required this.decodedBytes,
    required this.residentBytes,
    Iterable<TileCoordinate> children = const [],
  }) : children = List.unmodifiable(children) {
    if (!center.isFinite ||
        !radius.isFinite ||
        radius < 0 ||
        !geometricError.isFinite ||
        geometricError < 0 ||
        decodedBytes <= 0 ||
        residentBytes <= 0 ||
        coordinate.z < 0 ||
        this.children.length > 4 ||
        this.children.toSet().length != this.children.length ||
        this.children.any((c) => c.parent != coordinate)) {
      throw ArgumentError('Invalid tile bounds, sizes or quadtree children.');
    }
  }

  double screenError(Camera camera, ViewportMetrics viewport) {
    if (!viewport.isUsable) {
      throw ArgumentError('A usable viewport is required.');
    }
    if (camera is OrthographicCamera) {
      return geometricError *
          viewport.height *
          camera.zoom /
          (camera.top - camera.bottom);
    }
    if (camera is PerspectiveCamera) {
      final distance = math.max(
        1e-3,
        (center - camera.position).length - radius,
      );
      return geometricError *
          viewport.height *
          camera.zoom /
          (2 * math.tan(camera.fieldOfView / 2) * distance);
    }
    throw UnsupportedError(
      'Terrain requires a perspective or orthographic camera.',
    );
  }

  bool isVisible(Camera camera, ViewportMetrics viewport) {
    final delta = center - camera.position;
    final forward = (camera.target - camera.position).normalized();
    final right = forward.cross(camera.up).normalized();
    final up = right.cross(forward);
    final z = delta.dot(forward), x = delta.dot(right), y = delta.dot(up);
    if (camera is PerspectiveCamera) {
      if (z + radius < camera.near || z - radius > camera.far) return false;
      final ty = math.tan(camera.fieldOfView / 2) / camera.zoom;
      final tx = ty * viewport.aspect;
      return x.abs() <= z * tx + radius * math.sqrt(1 + tx * tx) &&
          y.abs() <= z * ty + radius * math.sqrt(1 + ty * ty);
    }
    if (camera is OrthographicCamera) {
      final cx = (camera.left + camera.right) / 2;
      final cy = (camera.top + camera.bottom) / 2;
      return z + radius >= camera.near &&
          z - radius <= camera.far &&
          (x - cx).abs() <=
              (camera.right - camera.left) / (2 * camera.zoom) + radius &&
          (y - cy).abs() <=
              (camera.top - camera.bottom) / (2 * camera.zoom) + radius;
    }
    throw UnsupportedError(
      'Terrain requires a perspective or orthographic camera.',
    );
  }
}

final class TileBudget {
  final int maxRequests,
      maxDecodedBytes,
      maxResidentBytes,
      maxSelectedTiles,
      maxAttempts;
  TileBudget({
    this.maxRequests = 4,
    this.maxDecodedBytes = 32 * 1024 * 1024,
    this.maxResidentBytes = 16 * 1024 * 1024,
    this.maxSelectedTiles = 256,
    this.maxAttempts = 3,
  }) {
    if ([
      maxRequests,
      maxDecodedBytes,
      maxResidentBytes,
      maxSelectedTiles,
      maxAttempts,
    ].any((v) => v <= 0)) {
      throw ArgumentError('Tile budgets must be positive.');
    }
  }
}

final class TileFailure {
  final String sourceIdentity;
  final TileCoordinate coordinate;
  final Object error;
  final int attempts;
  const TileFailure(
    this.sourceIdentity,
    this.coordinate,
    this.error,
    this.attempts,
  );
  @override
  String toString() =>
      '$sourceIdentity ${coordinate.z}/${coordinate.x}/${coordinate.y}: $error';
}

final class TileStreamingStats {
  final int selectedTiles,
      visibleTiles,
      activeRequests,
      cachedBytes,
      reservedBytes,
      residentBytes;
  final bool budgetLimited;
  const TileStreamingStats({
    required this.selectedTiles,
    required this.visibleTiles,
    required this.activeRequests,
    required this.cachedBytes,
    required this.reservedBytes,
    required this.residentBytes,
    required this.budgetLimited,
  });
}
