import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../tiling.dart';
import '../streaming/tile_source.dart';
import 'terrain_tile.dart';
import 'imagery_source.dart';
import 'terrain_pixels.dart';

final class ImageryLayer {
  final RasterImagerySource source;
  final double opacity;
  final int levelOffset;
  ImageryLayer(this.source, {this.opacity = 1, this.levelOffset = 0}) {
    if (!opacity.isFinite ||
        opacity < 0 ||
        opacity > 1 ||
        levelOffset.abs() > 24) {
      throw ArgumentError('Invalid imagery opacity or level offset.');
    }
  }
}

/// Reprojects imagery into terrain UVs while retaining the original geometry.
final class ImageryTerrainSource implements TerrainSource {
  static int _nextId = 0;
  final TerrainSource terrain;
  final List<ImageryLayer> layers;
  final int outputSize, maxTilesPerLayer;
  @override
  final String identity;
  ImageryTerrainSource({
    required this.terrain,
    required List<ImageryLayer> layers,
    this.outputSize = 256,
    this.maxTilesPerLayer = 4,
  }) : layers = List.unmodifiable(layers),
       identity = 'terrain-imagery:${_nextId++}' {
    if (layers.isEmpty ||
        layers.length > 4 ||
        outputSize < 2 ||
        outputSize > 2048 ||
        maxTilesPerLayer < 2 ||
        maxTilesPerLayer > 16) {
      throw ArgumentError(
        'Imagery requires 1-4 layers and bounded output dimensions.',
      );
    }
    for (final layer in layers) {
      final source = layer.source;
      if (source.tileSize < 1 ||
          source.tileSize > 2048 ||
          source.maximumLevel < 0 ||
          source.maximumLevel > 24 ||
          source.maxEncodedBytes < 1 ||
          source.maxEncodedBytes > 16 * 1024 * 1024 ||
          source.attribution.length > 8192) {
        throw ArgumentError('Invalid imagery source limits.');
      }
    }
  }
  @override
  Ellipsoid get ellipsoid => terrain.ellipsoid;
  @override
  Iterable<TileCoordinate> get roots => terrain.roots;
  int get _outputBytes => outputSize * outputSize * 4;
  int get _reservation =>
      _outputBytes * 3 +
      layers.fold<int>(
        0,
        (sum, layer) =>
            sum +
            layer.source.maxEncodedBytes +
            layer.source.decodedBytes * (maxTilesPerLayer * 2 + 2) +
            layer.source.attribution.length * 2,
      );
  @override
  TileMetadata describe(TileCoordinate coordinate) {
    final base = terrain.describe(coordinate);
    return TileMetadata(
      coordinate: coordinate,
      center: base.center,
      radius: base.radius,
      geometricError: base.geometricError,
      children: base.children,
      decodedBytes: base.decodedBytes * 2 + _reservation,
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
        'Imagery load requires its source identity and full reservation.',
      );
    }
    final base = await terrain.load(
      coordinate,
      TileLoadContext(
        sourceIdentity: terrain.identity,
        cancellation: context.cancellation,
        byteBudget: terrain.describe(coordinate).decodedBytes,
      ),
    );
    final decodedLayers = <_LayerPixels>[];
    final credits = {...base.attributions};
    for (final layer in layers) {
      if (layer.opacity == 0) continue;
      final source = layer.source;
      final coordinates = source.covering(
        base.imageryRectangle,
        coordinate.z + layer.levelOffset,
        maxTiles: maxTilesPerLayer,
      );
      if (coordinates.length > maxTilesPerLayer) {
        throw imageryFailure(AssetLoadError.limitExceeded);
      }
      if (coordinates.isNotEmpty &&
          coordinates.any((c) => c.z != coordinates.first.z)) {
        throw imageryFailure(AssetLoadError.invalidData);
      }
      final images = <TileCoordinate, ImageData>{};
      for (final coordinate in coordinates) {
        context.cancellation.throwIfCancelled();
        validateImageryCoordinate(
          source.projection,
          coordinate,
          source.maximumLevel,
        );
        final image = await source.load(coordinate, context.cancellation);
        if (image.size.width != source.tileSize ||
            image.size.height != source.tileSize ||
            image.pixels.length > source.decodedBytes) {
          throw imageryFailure(AssetLoadError.limitExceeded);
        }
        images[coordinate] = image;
      }
      if (images.isNotEmpty) {
        if (source.attribution.isNotEmpty) credits.add(source.attribution);
        decodedLayers.add(
          _LayerPixels(
            source.projection,
            layer.opacity,
            coordinates.first.z,
            images,
          ),
        );
      }
    }
    context.cancellation.throwIfCancelled();
    if (decodedLayers.isEmpty) return base;
    final image = base.imagery;
    final pixels = await _CompositionPool.run(
      _ImageJob(
        base.imageryRectangle,
        outputSize,
        ImageData(
          size: PhysicalSize(image.descriptor.width, image.descriptor.height),
          pixels: image.levels.first,
          colorSpace: image.descriptor.format == TextureFormat.rgba8UnormSrgb
              ? ColorSpace.srgb
              : ColorSpace.linear,
        ),
        decodedLayers,
      ),
      context.cancellation,
    );
    context.cancellation.throwIfCancelled();
    return TerrainTile(
      origin: base.origin,
      waterMask: base.waterMask,
      availability: base.availability,
      geometry: base.geometry,
      imageryRectangle: base.imageryRectangle,
      attributions: credits.toList()..sort(),
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

final class _LayerPixels {
  final ImageryProjection projection;
  final double opacity;
  final int level;
  final Map<TileCoordinate, ImageData> images;
  const _LayerPixels(this.projection, this.opacity, this.level, this.images);
}

final class _ImageJob {
  final GeographicRectangle rectangle;
  final int size;
  final ImageData base;
  final List<_LayerPixels> layers;
  const _ImageJob(this.rectangle, this.size, this.base, this.layers);
}

abstract final class _CompositionPool {
  static Future<Uint8List> run(_ImageJob job, LoadCancellation cancellation) =>
      TerrainCompositionPool.run(() => _runJob(job), cancellation);
}

Future<Uint8List> _runJob(_ImageJob job) => Isolate.run(() => _compose(job));

Uint8List _compose(_ImageJob job) {
  final pixels = Uint8List(job.size * job.size * 4);

  for (var y = 0; y < job.size; y++) {
    final v = (y + .5) / job.size;
    final latitude = job.rectangle.north - v * job.rectangle.height;
    for (var x = 0; x < job.size; x++) {
      final u = (x + .5) / job.size;
      final longitude = job.rectangle.west + u * job.rectangle.width;
      final result = sampleTerrainPixels(job.base, u, v);
      for (final layer in job.layers) {
        if (layer.projection == ImageryProjection.webMercator &&
            latitude.abs() > mercatorLatitudeLimit) {
          continue;
        }
        final height = 1 << layer.level,
            width =
                height *
                (layer.projection == ImageryProjection.geographic ? 2 : 1);
        final tx = ((longitude + math.pi) / (2 * math.pi) % 1) * width;
        final ty = (imageryY(layer.projection, latitude) * height).clamp(
          0.0,
          height.toDouble(),
        );
        final ix = tx.floor().clamp(0, width - 1),
            iy = ty.floor().clamp(0, height - 1);
        final image = layer.images[TileCoordinate(ix, iy, layer.level)];
        if (image == null) throw imageryFailure(AssetLoadError.invalidData);
        final above = sampleTerrainPixels(image, tx - ix, 1 - (ty - iy));
        final alpha = above[3] * layer.opacity;
        for (var c = 0; c < 3; c++) {
          result[c] = above[c] * layer.opacity + result[c] * (1 - alpha);
        }
        result[3] = alpha + result[3] * (1 - alpha);
      }
      final at = (y * job.size + x) * 4;
      storeTerrainPixel(pixels, at, result);
    }
  }
  return pixels;
}
