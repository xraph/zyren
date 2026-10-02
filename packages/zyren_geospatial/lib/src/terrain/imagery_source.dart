import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import '../tiling.dart';

enum ImageryProjection { geographic, webMercator }

enum ImageryUrlScheme { xyz, tms }

/// CPU imagery with south-origin tile coordinates and top-down pixels.
abstract class RasterImagerySource {
  String get identity;
  String get attribution;
  ImageryProjection get projection;
  int get tileSize;
  int get maximumLevel;
  int get maxEncodedBytes;
  int get decodedBytes => tileSize * tileSize * 4;
  Future<ImageData> load(
    TileCoordinate coordinate,
    LoadCancellation cancellation,
  );

  /// Reduces the level until the region fits its physical request limit.
  List<TileCoordinate> covering(
    GeographicRectangle rectangle,
    int level, {
    int maxTiles = 4,
  }) => imageryCoverage(
    projection,
    rectangle,
    level.clamp(0, maximumLevel),
    maxTiles,
  );
}

/// PNG/JPEG tile templates over the application's resolver and image decoder.
final class TemplateImagerySource extends RasterImagerySource {
  static int _nextId = 0;
  @override
  final String identity, attribution;
  @override
  final ImageryProjection projection;
  @override
  final int tileSize, maximumLevel, maxEncodedBytes;
  final ImageryUrlScheme urlScheme;
  final Uri _base;
  final String _template;
  final AssetServices _services;
  TemplateImagerySource({
    required Uri baseUri,
    required String template,
    required String datasetId,
    required AssetServices services,
    String version = '1',
    this.attribution = '',
    this.tileSize = 256,
    this.maximumLevel = 18,
    this.maxEncodedBytes = 1024 * 1024,
    this.projection = ImageryProjection.webMercator,
    this.urlScheme = ImageryUrlScheme.xyz,
  }) : _base = baseUri,
       _template = template,
       identity = 'imagery:$datasetId@$version:${_nextId++}',
       _services = _imageServices(services, tileSize, maxEncodedBytes) {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(datasetId) ||
        !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(version) ||
        !baseUri.hasScheme ||
        baseUri.hasFragment ||
        template.length > 8192 ||
        !['{x}', '{y}', '{z}'].every(template.contains) ||
        template
            .replaceAll(RegExp(r'\{[xyz]\}'), '')
            .contains(RegExp('[{}]')) ||
        maximumLevel < 0 ||
        maximumLevel > 24 ||
        attribution.length > 8192) {
      throw ArgumentError('Invalid imagery dataset, template or level limits.');
    }
    tileUri(const TileCoordinate(0, 0, 0));
  }

  Uri tileUri(TileCoordinate coordinate) {
    validateImageryCoordinate(projection, coordinate, maximumLevel);
    final height = 1 << coordinate.z;
    final y = urlScheme == ImageryUrlScheme.xyz
        ? height - coordinate.y - 1
        : coordinate.y;
    final uri = _base.resolve(
      _template
          .replaceAll('{z}', '${coordinate.z}')
          .replaceAll('{x}', '${coordinate.x}')
          .replaceAll('{y}', '$y'),
    );
    _services.policy.validate(_base, uri);
    return uri;
  }

  @override
  Future<ImageData> load(
    TileCoordinate coordinate,
    LoadCancellation cancellation,
  ) async {
    cancellation.throwIfCancelled();
    final work = _ImageryWork();
    final scope = AssetScope(
      services: AssetServices(
        resolver: _ImageryResolver(_services.resolver, work),
        imageDecoder: _services.imageDecoder,
        limits: _services.limits,
        policy: _services.policy,
        onCleanupError: _services.onCleanupError,
      ),
    );
    Registration? subscription;
    try {
      final task = scope.load(
        AssetRequest(
          uri: tileUri(coordinate),
          loader: _ImageryLoader(tileSize, work),
        ),
      );
      subscription = cancellation.onCancel(task.cancel);
      final data = await task.result;
      cancellation.throwIfCancelled();
      return data;
    } on LoadCancelled {
      rethrow;
    } on AssetLoadException catch (error) {
      throw imageryFailure(error.code);
    } catch (_) {
      cancellation.throwIfCancelled();
      throw imageryFailure(AssetLoadError.sourceFailed);
    } finally {
      subscription?.dispose();
      await scope.close();
      await work.settle();
      cancellation.throwIfCancelled();
    }
  }
}

AssetServices _imageServices(AssetServices source, int size, int maxBytes) {
  source.limits.validate();
  if (size < 1 ||
      size > 2048 ||
      maxBytes < 1 ||
      maxBytes > 16 * 1024 * 1024 ||
      source.imageDecoder == null ||
      size > source.limits.images.maxDimension ||
      size * size * 4 > source.limits.images.maxDecodedBytes ||
      size * size * 4 > source.limits.maxDecodedBytes) {
    throw ArgumentError(
      'Imagery requires a CPU decoder and dimensions within its limits.',
    );
  }
  int smaller(int a, int b) => a < b ? a : b;
  final encoded = smaller(
    maxBytes,
    smaller(
      source.limits.maxSourceBytes,
      smaller(
        source.limits.maxTotalSourceBytes,
        source.limits.images.maxEncodedBytes,
      ),
    ),
  );
  return AssetServices(
    resolver: source.resolver,
    imageDecoder: source.imageDecoder,
    policy: source.policy,
    onCleanupError: source.onCleanupError,
    limits: AssetLimits(
      maxSourceBytes: encoded,
      maxTotalSourceBytes: encoded,
      maxSources: 1,
      maxDecodedBytes: size * size * 4,
      images: ImageDecodeLimits(
        maxEncodedBytes: encoded,
        maxDecodedBytes: size * size * 4,
        maxDimension: size,
        maxWorkingBytes: source.limits.images.maxWorkingBytes,
      ),
    ),
  );
}

final class _ImageryLoader extends AssetLoader<ImageData> {
  final int size;
  final _ImageryWork work;
  const _ImageryLoader(this.size, this.work);
  @override
  Future<DecodedAsset<ImageData>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) => work.track(_decode(source, context));
  Future<DecodedAsset<ImageData>> _decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    final image = await _ImageryDecodePool.run(
      () => context.decodeImage(source.bytes),
      context.cancellation,
    );
    if (image.size.width != size || image.size.height != size) {
      throw imageryFailure(AssetLoadError.invalidData);
    }
    return DecodedAsset(create: () => image, release: (_) {});
  }
}

const double mercatorLatitudeLimit = 1.4844222297453324;
double imageryY(ImageryProjection projection, double latitude) =>
    projection == ImageryProjection.geographic
    ? (latitude + math.pi / 2) / math.pi
    : .5 +
          math.log(
                math.tan(
                  math.pi / 4 +
                      latitude.clamp(
                            -mercatorLatitudeLimit,
                            mercatorLatitudeLimit,
                          ) /
                          2,
                ),
              ) /
              (2 * math.pi);

void validateImageryCoordinate(
  ImageryProjection projection,
  TileCoordinate c,
  int maximumLevel,
) {
  if (c.z < 0 ||
      c.z > maximumLevel ||
      c.x < 0 ||
      c.y < 0 ||
      c.x >=
          (projection == ImageryProjection.geographic ? 2 : 1) * (1 << c.z) ||
      c.y >= 1 << c.z) {
    throw RangeError('Imagery coordinate is outside the source.');
  }
}

List<TileCoordinate> imageryCoverage(
  ImageryProjection projection,
  GeographicRectangle rectangle,
  int level,
  int maxTiles,
) {
  if (rectangle.toList().any((v) => !v.isFinite) ||
      rectangle.width <= 0 ||
      rectangle.width > 2 * math.pi ||
      rectangle.height <= 0 ||
      rectangle.south < -math.pi / 2 ||
      rectangle.north > math.pi / 2 ||
      level < 0 ||
      level > 24 ||
      maxTiles < 1 ||
      maxTiles > 64) {
    throw ArgumentError('Invalid imagery region or request limit.');
  }
  if (projection == ImageryProjection.webMercator &&
      (rectangle.south >= mercatorLatitudeLimit ||
          rectangle.north <= -mercatorLatitudeLimit)) {
    return const [];
  }
  while (true) {
    final height = 1 << level,
        width = (projection == ImageryProjection.geographic ? 2 : 1) * height;
    final west = ((rectangle.west + math.pi) / (2 * math.pi)) % 1;
    final east = west + rectangle.width / (2 * math.pi);
    final firstX = (west * width).floor(), lastX = (east * width).ceil() - 1;
    final firstY = (imageryY(projection, rectangle.south) * height)
        .floor()
        .clamp(0, height - 1);
    final lastY =
        (imageryY(projection, rectangle.north) * height).ceil().clamp(
          1,
          height,
        ) -
        1;
    if ((lastX - firstX + 1) * (lastY - firstY + 1) <= maxTiles) {
      return {
        for (var y = firstY; y <= lastY; y++)
          for (var x = firstX; x <= lastX; x++)
            TileCoordinate(x % width, y, level),
      }.toList();
    }
    if (level == 0) throw imageryFailure(AssetLoadError.limitExceeded);
    level--;
  }
}

AssetLoadException imageryFailure(AssetLoadError code) =>
    AssetLoadException(code, 'Imagery source failed (${code.name}).');

final class _ImageryWork {
  final _pending = <Future<void>>{};
  Future<T> track<T>(Future<T> future) {
    late final Future<void> done;
    done = future
        .then<void>((_) {}, onError: (Object _) {})
        .whenComplete(() => _pending.remove(done));
    _pending.add(done);
    return future;
  }

  Future<void> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(List.of(_pending));
    }
  }
}

final class _ImageryResolver implements ByteSourceResolver {
  final ByteSourceResolver delegate;
  final _ImageryWork work;
  const _ImageryResolver(this.delegate, this.work);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) =>
      work.track(delegate.read(uri, context));
}

abstract final class _ImageryDecodePool {
  static int _active = 0;
  static final _queue = Queue<Completer<void>>();
  static Future<ImageData> run(
    Future<ImageData> Function() decode,
    LoadCancellation cancellation,
  ) async {
    if (_active < 2) {
      _active++;
    } else {
      if (_queue.length >= 16) {
        throw imageryFailure(AssetLoadError.limitExceeded);
      }
      final gate = Completer<void>();
      _queue.add(gate);
      await gate.future;
    }
    try {
      cancellation.throwIfCancelled();
      return await decode();
    } finally {
      if (_queue.isEmpty) {
        _active--;
      } else {
        _queue.removeFirst().complete();
      }
    }
  }
}
