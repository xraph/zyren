import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../tiling.dart';
import '../streaming/tile_source.dart';
import 'terrain_tile.dart';
import 'terrain_extensions.dart';
import 'terrain_pixels.dart';

/// Ordered, immutable draped imagery. Colors use linear RGB.
sealed class TerrainOverlay {
  final Color3 color;
  final double opacity;
  TerrainOverlay({required this.color, this.opacity = 1}) {
    color.toList();
    if (!opacity.isFinite || opacity < 0 || opacity > 1) {
      throw ArgumentError('Overlay opacity must be in [0, 1].');
    }
  }
  int get _vertices;
}

final class WaterTintOverlay extends TerrainOverlay {
  WaterTintOverlay({required super.color, super.opacity});
  @override
  int get _vertices => 1;
}

/// Filled outer ring followed by holes, joined by straight lon/lat segments.
/// Rings span less than half the globe and may cross the dateline.
final class TerrainPolygonOverlay extends TerrainOverlay {
  final List<List<Geodetic>> rings;
  TerrainPolygonOverlay({
    required List<List<Geodetic>> rings,
    required super.color,
    super.opacity,
  }) : rings = _rings(rings);
  @override
  int get _vertices => rings.fold(0, (n, ring) => n + ring.length);
}

/// A draped line with round joins/caps. Width is measured in output texels.
final class TerrainPolylineOverlay extends TerrainOverlay {
  final List<Geodetic> points;
  final double width;
  TerrainPolylineOverlay({
    required List<Geodetic> points,
    required super.color,
    super.opacity,
    this.width = 2,
  }) : points = _path(points, 2) {
    if (!width.isFinite || width <= 0 || width > 128) {
      throw ArgumentError('Line width must be in (0, 128] texels.');
    }
  }
  @override
  int get _vertices => points.length;
}

List<List<Geodetic>> _rings(List<List<Geodetic>> rings) {
  if (rings.isEmpty ||
      rings.length > 32 ||
      rings.fold<int>(0, (n, r) => n + r.length) > 4096) {
    throw ArgumentError('Use 1-32 rings and at most 4096 vertices.');
  }
  return List.unmodifiable(rings.map((ring) => _path(ring, 3)));
}

double _wrap(double value) => (value + math.pi) % (2 * math.pi) - math.pi;
List<Geodetic> _path(List<Geodetic> points, int minimum) {
  if (points.length < minimum || points.length > 4096) {
    throw ArgumentError('Invalid overlay path size.');
  }
  var previous = _wrap(points.first.longitude), low = previous, high = previous;
  for (final point in points.skip(1)) {
    final delta = _wrap(point.longitude - previous);
    if (delta.abs() >= math.pi - 1e-10) {
      throw ArgumentError(
        'Overlay segments must take an unambiguous short path.',
      );
    }
    previous += delta;
    low = math.min(low, previous);
    high = math.max(high, previous);
  }
  if (high - low >= math.pi) {
    throw ArgumentError('Overlay paths must span less than half the globe.');
  }
  return List.unmodifiable(
    points.map((p) => Geodetic(_wrap(p.longitude), p.latitude)),
  );
}

/// Composites water and vector overlays without replacing terrain geometry.
final class OverlayTerrainSource implements TerrainSource {
  static int _nextId = 0;
  final TerrainSource terrain;
  final List<TerrainOverlay> overlays;
  final int outputSize, maxSampleTests;
  @override
  final String identity;
  OverlayTerrainSource({
    required this.terrain,
    required List<TerrainOverlay> overlays,
    this.outputSize = 256,
    this.maxSampleTests = 64 * 1024 * 1024,
  }) : overlays = List.unmodifiable(overlays),
       identity = 'terrain-overlays:${_nextId++}' {
    if (overlays.isEmpty ||
        overlays.length > 64 ||
        outputSize < 2 ||
        outputSize > 1024 ||
        maxSampleTests < 1 ||
        maxSampleTests > 256 * 1024 * 1024 ||
        _vertexCount > 4096 ||
        outputSize * outputSize * _vertexCount * 4 > maxSampleTests) {
      throw ArgumentError(
        'Overlay dimensions, vertices or sample work exceed their limits.',
      );
    }
  }
  int get _vertexCount => overlays.fold(0, (n, layer) => n + layer._vertices);
  @override
  Ellipsoid get ellipsoid => terrain.ellipsoid;
  @override
  Iterable<TileCoordinate> get roots => terrain.roots;
  @override
  TileMetadata describe(TileCoordinate coordinate) {
    final base = terrain.describe(coordinate);
    return TileMetadata(
      coordinate: coordinate,
      center: base.center,
      radius: base.radius,
      geometricError: base.geometricError,
      children: base.children,
      decodedBytes:
          base.decodedBytes * 2 +
          outputSize * outputSize * 12 +
          _vertexCount * 64,
      residentBytes:
          base.residentBytes +
          TextureDescriptor(
            width: outputSize,
            height: outputSize,
            mipLevels: outputSize.bitLength,
          ).byteLength,
    );
  }

  @override
  Future<TerrainTile> load(
    TileCoordinate coordinate,
    TileLoadContext context,
  ) async {
    context.cancellation.throwIfCancelled();
    if (context.sourceIdentity != identity ||
        context.byteBudget < describe(coordinate).decodedBytes) {
      throw ArgumentError(
        'Overlay load requires its source identity and full reservation.',
      );
    }
    final reservation = terrain.describe(coordinate);
    final tile = await terrain.load(
      coordinate,
      TileLoadContext(
        sourceIdentity: terrain.identity,
        cancellation: context.cancellation,
        byteBudget: reservation.decodedBytes,
      ),
    );
    context.cancellation.throwIfCancelled();
    if (tile.decodedBytes > reservation.decodedBytes ||
        tile.residentBytes > reservation.residentBytes) {
      throw AssetLoadException(
        AssetLoadError.limitExceeded,
        'Terrain payload exceeds its reservation.',
      );
    }
    final image = tile.imagery, rectangle = tile.imageryRectangle;
    if (image.descriptor.format != TextureFormat.rgba8Unorm &&
        image.descriptor.format != TextureFormat.rgba8UnormSrgb) {
      throw AssetLoadException(
        AssetLoadError.unsupportedFeature,
        'Terrain overlays require RGBA8 imagery.',
      );
    }
    if (rectangle.width <= 0 ||
        rectangle.width > 2 * math.pi ||
        rectangle.height <= 0 ||
        rectangle.toList().any((n) => !n.isFinite)) {
      throw AssetLoadException(
        AssetLoadError.invalidData,
        'Invalid overlay terrain rectangle.',
      );
    }
    final job = _OverlayJob(
      rectangle,
      outputSize,
      overlays,
      tile.waterMask,
      ImageData(
        size: PhysicalSize(image.descriptor.width, image.descriptor.height),
        pixels: image.levels.first,
        colorSpace: image.descriptor.format == TextureFormat.rgba8UnormSrgb
            ? ColorSpace.srgb
            : ColorSpace.linear,
      ),
    );
    final pixels = await TerrainCompositionPool.run(
      () => _run(job),
      context.cancellation,
    );
    return TerrainTile(
      origin: tile.origin,
      geometry: tile.geometry,
      imageryRectangle: rectangle,
      waterMask: tile.waterMask,
      availability: tile.availability,
      attributions: tile.attributions,
      imagery: TextureImage.rgba(
        width: outputSize,
        height: outputSize,
        pixels: pixels,
        generateMipmaps: true,
        mipmapAlphaFilter: MipmapAlphaFilter.weighted,
      ),
    );
  }
}

final class _OverlayJob {
  final GeographicRectangle rectangle;
  final int size;
  final List<TerrainOverlay> overlays;
  final TerrainWaterMask? water;
  final ImageData base;
  const _OverlayJob(
    this.rectangle,
    this.size,
    this.overlays,
    this.water,
    this.base,
  );
}

Future<Uint8List> _run(_OverlayJob job) => Isolate.run(() => _compose(job));

typedef _Point = (double, double);

final class _Projected {
  final TerrainOverlay overlay;
  final List<List<_Point>> paths;
  final double centerX, period;
  _Projected(this.overlay, _OverlayJob job)
    : paths = [],
      centerX = _center(overlay, job),
      period = 2 * math.pi / job.rectangle.width * job.size {
    final input = switch (overlay) {
      TerrainPolygonOverlay(:final rings) => rings,
      TerrainPolylineOverlay(:final points) => [points],
      WaterTintOverlay() => <List<Geodetic>>[],
    };
    final anchor =
        job.rectangle.west + centerX / job.size * job.rectangle.width;
    for (final path in input) {
      var lon = anchor + _wrap(path.first.longitude - anchor);
      final projected = <_Point>[];
      for (final point in path) {
        lon += _wrap(point.longitude - lon);
        projected.add((
          (lon - job.rectangle.west) / job.rectangle.width * job.size,
          (job.rectangle.north - point.latitude) /
              job.rectangle.height *
              job.size,
        ));
      }
      paths.add(projected);
    }
  }
  static double _center(TerrainOverlay overlay, _OverlayJob job) {
    final path = switch (overlay) {
      TerrainPolygonOverlay(:final rings) => rings.first,
      TerrainPolylineOverlay(:final points) => points,
      WaterTintOverlay() => <Geodetic>[],
    };
    if (path.isEmpty) return job.size / 2;
    final middle = job.rectangle.west + job.rectangle.width / 2;
    var lon = middle + _wrap(path.first.longitude - middle),
        low = lon,
        high = lon;
    for (final point in path.skip(1)) {
      lon += _wrap(point.longitude - lon);
      low = math.min(low, lon);
      high = math.max(high, lon);
    }
    return ((low + high) / 2 - job.rectangle.west) /
        job.rectangle.width *
        job.size;
  }

  bool hit(double x, double y) {
    x += ((centerX - x) / period).round() * period;
    if (overlay is TerrainPolygonOverlay) {
      return _inside(paths.first, x, y) &&
          !paths.skip(1).any((path) => _inside(path, x, y));
    }
    final radius = (overlay as TerrainPolylineOverlay).width / 2;
    final path = paths.single;
    for (var i = 1; i < path.length; i++) {
      final a = path[i - 1], b = path[i], dx = b.$1 - a.$1, dy = b.$2 - a.$2;
      final length2 = dx * dx + dy * dy;
      final t = length2 == 0
          ? 0.0
          : (((x - a.$1) * dx + (y - a.$2) * dy) / length2).clamp(0.0, 1.0);
      final sx = x - a.$1 - dx * t, sy = y - a.$2 - dy * t;
      if (sx * sx + sy * sy <= radius * radius) return true;
    }
    return false;
  }
}

bool _inside(List<_Point> path, double x, double y) {
  var inside = false;
  for (var i = 0, j = path.length - 1; i < path.length; j = i++) {
    final a = path[i], b = path[j];
    if ((a.$2 > y) != (b.$2 > y) &&
        x < (b.$1 - a.$1) * (y - a.$2) / (b.$2 - a.$2) + a.$1) {
      inside = !inside;
    }
  }
  return inside;
}

double _water(TerrainWaterMask mask, double u, double v) {
  if (mask.size == 1) return mask.bytes[0] / 255;
  final x = (u * 256 - .5).clamp(0.0, 255.0),
      y = (v * 256 - .5).clamp(0.0, 255.0);
  final ix = x.floor(), iy = y.floor(), fx = x - ix, fy = y - iy;
  double at(int x, int y) => mask.bytes[y * 256 + x] / 255;
  return at(ix, iy) * (1 - fx) * (1 - fy) +
      at(math.min(ix + 1, 255), iy) * fx * (1 - fy) +
      at(ix, math.min(iy + 1, 255)) * (1 - fx) * fy +
      at(math.min(ix + 1, 255), math.min(iy + 1, 255)) * fx * fy;
}

Uint8List _compose(_OverlayJob job) {
  final pixels = Uint8List(job.size * job.size * 4);
  final layers = [
    for (final layer in job.overlays)
      if (layer.opacity > 0) _Projected(layer, job),
  ];
  for (var y = 0; y < job.size; y++) {
    for (var x = 0; x < job.size; x++) {
      final u = (x + .5) / job.size, v = (y + .5) / job.size;
      final result = sampleTerrainPixels(job.base, u, v);
      for (final layer in layers) {
        double coverage;
        if (layer.overlay is WaterTintOverlay) {
          coverage = job.water == null ? 0 : _water(job.water!, u, v);
        } else {
          var hits = 0;
          for (final dx in [.25, .75]) {
            for (final dy in [.25, .75]) {
              if (layer.hit(x + dx, y + dy)) hits++;
            }
          }
          coverage = hits / 4;
        }
        final alpha = coverage * layer.overlay.opacity,
            color = layer.overlay.color;
        result[0] = color.r * alpha + result[0] * (1 - alpha);
        result[1] = color.g * alpha + result[1] * (1 - alpha);
        result[2] = color.b * alpha + result[2] * (1 - alpha);
        result[3] = alpha + result[3] * (1 - alpha);
      }
      storeTerrainPixel(pixels, (y * job.size + x) * 4, result);
    }
  }
  return pixels;
}
