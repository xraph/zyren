import 'dart:async';
import 'dart:math' as math;
import '../tiling.dart';
import '../terrain/imagery_source.dart'
    show ImageryProjection, imageryY, mercatorLatitudeLimit;
import 'coverage.dart';
import 'policy.dart';
import 'region.dart';
import 'resource_key.dart';

final class GeoRegionLimits {
  final int maxResources, maxBytes;
  const GeoRegionLimits({
    this.maxResources = 4096,
    this.maxBytes = 256 * 1024 * 1024,
  });
  void validate() {
    if (maxResources < 1 ||
        maxResources > 10000 ||
        maxBytes < 1 ||
        maxBytes > 1 << 40) {
      throw ArgumentError('Invalid region planning budget.');
    }
  }
}

abstract interface class GeoRegionSource {
  GeoSourceMetadata get metadata;
  GeoCoverage get coverage;
  FutureOr<Iterable<GeoPlannedResource>> enumerate(
    GeoOfflineRegion region,
    GeoRegionLimits limits,
  );
}

final class GeoSourceCatalog {
  final Map<String, GeoRegionSource> _sources = {};
  void register(GeoRegionSource source) {
    if (_sources.length >= 64 ||
        _sources.containsKey(source.metadata.sourceId)) {
      throw ArgumentError(
        'Duplicate or excessive geographic source registration.',
      );
    }
    _sources[source.metadata.sourceId] = source;
  }

  Future<GeoRegionPlan> plan(
    GeoOfflineRegion region, {
    GeoRegionLimits limits = const GeoRegionLimits(),
  }) async {
    limits.validate();
    final resources = <GeoPlannedResource>[], credits = <String>{};
    var bytes = 0, complete = true;
    for (final entry in region.sourceVersions.entries) {
      final source = _sources[entry.key];
      if (source == null ||
          source.metadata.sourceVersion != entry.value ||
          !source.metadata.mayExportOffline) {
        throw const GeoDataException(GeoDataError.denied);
      }
      credits.addAll(source.metadata.credits);
      complete =
          source.coverage.covers(
            region.bounds,
            minimumLevel: region.minimumLevel,
            maximumLevel: region.maximumLevel,
            start: region.start,
            end: region.end,
          ) &&
          complete;
      final remaining = GeoRegionLimits(
        maxResources: limits.maxResources - resources.length,
        maxBytes: limits.maxBytes - bytes,
      );
      if (remaining.maxResources < 1 || remaining.maxBytes < 1) {
        throw const GeoDataException(GeoDataError.budgetExceeded);
      }
      for (final resource in await source.enumerate(region, remaining)) {
        bytes += resource.estimatedBytes;
        if (resources.length >= limits.maxResources ||
            bytes > limits.maxBytes) {
          throw const GeoDataException(GeoDataError.budgetExceeded);
        }
        resources.add(resource);
      }
    }
    return GeoRegionPlan(
      region: region,
      resources: resources,
      coverageComplete: complete,
      credits: credits,
      maxResources: limits.maxResources,
      maxBytes: limits.maxBytes,
    );
  }
}

/// Enumerates exact requested levels plus ancestors for fallback. It never
/// silently lowers detail to make an offline download fit its budget.
final class GeoTileRegionSource implements GeoRegionSource {
  @override
  final GeoSourceMetadata metadata;
  @override
  final GeoCoverage coverage;
  final ImageryProjection projection;
  final GeoResourceKey Function(TileCoordinate) keyForTile;
  final int estimatedTileBytes;
  final List<GeoPlannedResource> prerequisites;
  final bool allowGlobal;
  GeoTileRegionSource({
    required this.metadata,
    required GeoCoverage coverage,
    required this.projection,
    required this.keyForTile,
    required this.estimatedTileBytes,
    Iterable<GeoPlannedResource> prerequisites = const [],
    this.allowGlobal = false,
  }) : coverage = GeoCoverage(
         rectangles: coverage.rectangles
             .map(
               (r) => projection == ImageryProjection.webMercator
                   ? GeographicRectangle(
                       r.west,
                       math.max(r.south, -mercatorLatitudeLimit),
                       r.east,
                       math.min(r.north, mercatorLatitudeLimit),
                     )
                   : r,
             )
             .where((r) => r.height > 0),
         known: coverage.known,
         minimumLevel: coverage.minimumLevel,
         maximumLevel: coverage.maximumLevel,
         start: coverage.start,
         end: coverage.end,
       ),
       prerequisites = List.unmodifiable(prerequisites.take(1025)) {
    if (estimatedTileBytes < 1 ||
        estimatedTileBytes > 512 * 1024 * 1024 ||
        this.prerequisites.length > 1024) {
      throw ArgumentError('Invalid tile resource estimates.');
    }
  }
  @override
  List<GeoPlannedResource> enumerate(
    GeoOfflineRegion region,
    GeoRegionLimits limits,
  ) {
    limits.validate();
    final bounds = region.bounds;
    if (!allowGlobal &&
        bounds.width >= 2 * math.pi &&
        bounds.height >= math.pi) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    final resources = List<GeoPlannedResource>.of(prerequisites);
    var bytes = resources.fold(0, (n, r) => n + r.estimatedBytes);
    final tiles = <TileCoordinate>{};
    for (var z = 0; z <= region.maximumLevel; z++) {
      final height = 1 << z,
          width = (projection == ImageryProjection.geographic ? 2 : 1) * height;
      for (final part in splitGeoBounds(bounds)) {
        final limit = projection == ImageryProjection.geographic
            ? math.pi / 2
            : mercatorLatitudeLimit;
        final south = math.max(part.south, -limit),
            north = math.min(part.north, limit);
        if (south >= north) continue;
        final firstX = (((part.west + math.pi) / (2 * math.pi)) * width)
            .floor()
            .clamp(0, width - 1);
        final lastX =
            ((((part.east + math.pi) / (2 * math.pi)) * width).ceil() - 1)
                .clamp(0, width - 1);
        final firstY = (imageryY(projection, south) * height).floor().clamp(
          0,
          height - 1,
        );
        final lastY = ((imageryY(projection, north) * height).ceil() - 1).clamp(
          0,
          height - 1,
        );
        final count = (lastX - firstX + 1) * (lastY - firstY + 1);
        if (count > limits.maxResources - resources.length ||
            count * estimatedTileBytes > limits.maxBytes - bytes) {
          throw const GeoDataException(GeoDataError.budgetExceeded);
        }
        for (var y = firstY; y <= lastY; y++) {
          for (var x = firstX; x <= lastX; x++) {
            final tile = TileCoordinate(x, y, z);
            if (!tiles.add(tile)) continue;
            resources.add(
              GeoPlannedResource(
                key: keyForTile(tile),
                estimatedBytes: estimatedTileBytes,
                dependencies: prerequisites.map((r) => r.key),
              ),
            );
            bytes += estimatedTileBytes;
          }
        }
      }
    }
    if (resources.length > limits.maxResources || bytes > limits.maxBytes) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    return resources;
  }
}
