import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../tiling.dart';
import '../streaming/tile_source.dart';
import 'terrain_tile.dart';
import 'quantized_mesh_decoder.dart';
import 'terrain_extensions.dart';

/// EPSG:4326/TMS quantized-mesh layers over a host-provided resolver.
/// Supply authentication in that resolver. Dataset IDs must contain no secrets.
/// Incomplete sibling coverage stays at the parent until fill tiles are supported.
final class QuantizedMeshTerrainSource implements TerrainSource {
  static int _nextInstance = 0;
  final ByteSourceResolver _resolver;
  final SourcePolicy _policy;
  final Uri _base;
  final String _template;
  final List<String> _extensions;
  final int? metadataAvailability;
  final int maxAvailabilityPages, maxAvailabilityRanges;
  final _pages = <TileCoordinate, TerrainAvailabilityMetadata>{};
  int _rangeCount = 0;
  final List<List<_Availability>>? _available;
  final TilingScheme _scheme = TilingScheme();
  @override
  final String identity;
  final String version, attribution;
  final int maximumLevel;
  final QuantizedMeshLimits limits;
  final double minimumHeight,
      maximumHeight,
      skirtDepth,
      levelZeroGeometricError;
  @override
  Ellipsoid get ellipsoid => Ellipsoid.wgs84;

  QuantizedMeshTerrainSource._({
    required ByteSourceResolver resolver,
    required SourcePolicy policy,
    required Uri base,
    required String template,
    required List<String> extensions,
    required this.metadataAvailability,
    required this.maxAvailabilityPages,
    required this.maxAvailabilityRanges,
    required List<List<_Availability>>? available,
    required String datasetId,
    required this.version,
    required this.attribution,
    required this.maximumLevel,
    required this.limits,
    required this.minimumHeight,
    required this.maximumHeight,
    required this.skirtDepth,
    required this.levelZeroGeometricError,
  }) : _resolver = resolver,
       _policy = policy,
       _base = base,
       _template = template,
       _extensions = List.unmodifiable(extensions),
       _available = available,
       identity = 'quantized:$datasetId@$version:${_nextInstance++}';

  /// Reads only layer.json. Every tile request has its own cancellation signal.
  /// [levelZeroGeometricError] is a host estimate in metres, halved per level;
  /// the wire format does not provide a per-tile geometric error.
  static Future<QuantizedMeshTerrainSource> open({
    required Uri uri,
    required String datasetId,
    required ByteSourceResolver resolver,
    required LoadCancellation cancellation,
    SourcePolicy policy = const SourcePolicy(),
    QuantizedMeshLimits? limits,
    int maxManifestBytes = 1024 * 1024,
    int maxAvailabilityPages = 1024,
    int maxAvailabilityRanges = 16384,
    double minimumHeight = -12000,
    double maximumHeight = 10000,
    double skirtDepth = 50,
    double levelZeroGeometricError = 100000,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(datasetId) ||
        maxAvailabilityPages < 1 ||
        maxAvailabilityPages > 65536 ||
        maxAvailabilityRanges < 1 ||
        maxAvailabilityRanges > 262144 ||
        maxManifestBytes < 1 ||
        maxManifestBytes > 4 * 1024 * 1024 ||
        !minimumHeight.isFinite ||
        !maximumHeight.isFinite ||
        minimumHeight < -100000 ||
        maximumHeight > 100000 ||
        minimumHeight > maximumHeight ||
        !skirtDepth.isFinite ||
        skirtDepth < 0 ||
        skirtDepth > 100000 ||
        !levelZeroGeometricError.isFinite ||
        levelZeroGeometricError <= 0) {
      throw ArgumentError(
        'Use a public dataset ID, bounded reads and finite terrain settings.',
      );
    }
    final resolved = await _read(
      resolver,
      uri,
      policy,
      cancellation,
      maxManifestBytes,
    );
    try {
      final json = terrainJson(resolved.bytes, maxManifestBytes);
      for (final (name, expected) in [
        ('format', 'quantized-mesh-1.0'),
        ('scheme', 'tms'),
        ('projection', 'EPSG:4326'),
        ('minzoom', 0),
      ]) {
        if (json.containsKey(name) && json[name] != expected) _unsupported();
      }
      if (json.containsKey('parentUrl')) {
        _unsupported();
      }
      final zoom = json['maxzoom'];
      if (zoom is! int || zoom < 0 || zoom > 30) _invalid();
      final version = json['version'] ?? '1.0.0';
      if (version is! String ||
          !RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(version)) {
        _invalid();
      }
      final tiles = json['tiles'];
      if (tiles is! List || tiles.isEmpty || tiles.first is! String) _invalid();
      final template = tiles.first as String;
      if (template.length > 8192 ||
          !['{x}', '{y}', '{z}'].every(template.contains) ||
          template
              .replaceAll(RegExp(r'\{(?:x|y|z|version)\}'), '')
              .contains(RegExp(r'[{}]'))) {
        _invalid();
      }
      final attribution = json['attribution'] ?? '';
      if (attribution is! String || attribution.length > 8192) _invalid();
      final extensions = json['extensions'] ?? <String>[];
      if (extensions is! List || extensions.any((e) => e is! String)) {
        _invalid();
      }
      final interval = json['metadataAvailability'];
      if (interval != null &&
          (interval is! int || interval < 1 || interval > 30)) {
        _invalid();
      }
      if (interval != null && !extensions.contains('metadata')) _unsupported();
      final availability = json['available'];
      List<List<_Availability>>? available;
      if (interval == null && json.containsKey('available')) {
        if (availability is! List || availability.length > zoom + 1) _invalid();
        var total = 0;
        available = [];
        for (var z = 0; z < availability.length; z++) {
          final ranges = availability[z];
          if (ranges is! List) _invalid();
          total += ranges.length;
          if (total > 4096) _invalid();
          final level = <_Availability>[];
          for (final range in ranges) {
            if (range is! Map<String, dynamic>) _invalid();
            final values = [
              'startX',
              'startY',
              'endX',
              'endY',
            ].map((k) => range[k]).toList();
            if (values.any((n) => n is! int)) _invalid();
            final x = values[0] as int,
                y = values[1] as int,
                endX = values[2] as int,
                endY = values[3] as int;
            if (x < 0 ||
                y < 0 ||
                endX < x ||
                endY < y ||
                endX >= 2 * (1 << z) ||
                endY >= 1 << z) {
              _invalid();
            }
            level.add(_Availability(x, y, endX, endY));
          }
          available.add(List.unmodifiable(level));
        }
        available = List.unmodifiable(available);
      }
      final source = QuantizedMeshTerrainSource._(
        resolver: resolver,
        policy: policy,
        base: resolved.effectiveUri,
        template: template,
        extensions: [
          'octvertexnormals',
          'watermask',
          'metadata',
        ].where(extensions.contains).toList(),
        metadataAvailability: interval as int?,
        maxAvailabilityPages: maxAvailabilityPages,
        maxAvailabilityRanges: maxAvailabilityRanges,
        available: available,
        datasetId: datasetId,
        version: version,
        attribution: attribution,
        maximumLevel: zoom,
        limits: limits ?? QuantizedMeshLimits(),
        minimumHeight: minimumHeight,
        maximumHeight: maximumHeight,
        skirtDepth: skirtDepth,
        levelZeroGeometricError: levelZeroGeometricError,
      );
      if (source.roots.isEmpty) _invalid();
      // Resolve every substitution class once before accepting the manifest.
      source._uri(const TileCoordinate(0, 0, 0));
      cancellation.throwIfCancelled();
      return source;
    } on LoadCancelled {
      rethrow;
    } on AssetLoadException catch (error) {
      throw _sanitized(error.code);
    } catch (_) {
      throw _sanitized(AssetLoadError.invalidData);
    }
  }

  @override
  Iterable<TileCoordinate> get roots sync* {
    for (var x = 0; x < 2; x++) {
      final tile = TileCoordinate(x, 0, 0);
      if (_has(tile)) yield tile;
    }
  }

  /// Unknown coordinates are not requested until an ancestor publishes coverage.
  TerrainAvailability availabilityOf(TileCoordinate tile) {
    if (tile.z < 0 ||
        tile.z > maximumLevel ||
        tile.x < 0 ||
        tile.y < 0 ||
        tile.x >= 2 * (1 << tile.z) ||
        tile.y >= 1 << tile.z) {
      return TerrainAvailability.unavailable;
    }
    final interval = metadataAvailability;
    if (interval == null) {
      final available = _available;
      return available == null ||
              tile.z < available.length &&
                  available[tile.z].any((range) => range.contains(tile))
          ? TerrainAvailability.available
          : TerrainAvailability.unavailable;
    }
    for (var level = 1; level <= tile.z; level++) {
      final pageLevel = (level - 1) ~/ interval * interval;
      final pageTile = TileCoordinate(
        tile.x >> (tile.z - pageLevel),
        tile.y >> (tile.z - pageLevel),
        pageLevel,
      );
      final page = _pages[pageTile];
      if (page == null) return TerrainAvailability.unknown;
      final offset = level - pageLevel - 1;
      final ancestor = TileCoordinate(
        tile.x >> (tile.z - level),
        tile.y >> (tile.z - level),
        level,
      );
      if (offset >= page.levels.length ||
          !page.levels[offset].any((r) => r.contains(ancestor))) {
        return TerrainAvailability.unavailable;
      }
    }
    return TerrainAvailability.available;
  }

  bool _has(TileCoordinate tile) =>
      availabilityOf(tile) == TerrainAvailability.available;

  void _recordAvailability(
    TileCoordinate tile,
    TerrainAvailabilityMetadata? page,
  ) {
    final interval = metadataAvailability;
    if (interval == null || tile.z % interval != 0 || tile.z == maximumLevel) {
      return;
    }
    if (page == null ||
        page.levels.length > math.min(interval, maximumLevel - tile.z)) {
      _invalid();
    }
    for (var offset = 0; offset < page.levels.length; offset++) {
      final scale = 1 << (offset + 1);
      for (final range in page.levels[offset]) {
        if (range.startX < tile.x * scale ||
            range.endX >= (tile.x + 1) * scale ||
            range.startY < tile.y * scale ||
            range.endY >= (tile.y + 1) * scale) {
          _invalid();
        }
      }
    }
    final previous = _pages[tile];
    if (previous != null) {
      if (previous.levels.length != page.levels.length) _invalid();
      for (var i = 0; i < page.levels.length; i++) {
        if (previous.levels[i].length != page.levels[i].length ||
            previous.levels[i].toSet().length !=
                page.levels[i].toSet().length ||
            !previous.levels[i].toSet().containsAll(page.levels[i])) {
          _invalid();
        }
      }
      return;
    }
    if (_pages.length >= maxAvailabilityPages ||
        _rangeCount + page.rangeCount > maxAvailabilityRanges) {
      throw _sanitized(AssetLoadError.limitExceeded);
    }
    _pages[tile] = page;
    _rangeCount += page.rangeCount;
  }

  void _validate(TileCoordinate tile) {
    if (!_has(tile)) throw RangeError('Terrain coordinate is unavailable.');
  }

  @override
  TileMetadata describe(TileCoordinate coordinate) {
    _validate(coordinate);
    final rectangle = _scheme.getRectangle(coordinate);
    final center = Geodetic(
      rectangle.west + rectangle.width / 2,
      (rectangle.south + rectangle.north) / 2,
    ).toEcef();
    final scale =
        ellipsoid.maximumRadius *
        ellipsoid.maximumRadius /
        ellipsoid.minimumRadius;
    final height =
        math.max(minimumHeight.abs(), maximumHeight.abs()) + skirtDepth;
    final children = coordinate.z == maximumLevel
        ? <TileCoordinate>[]
        : coordinate.traverseChildren(1).toList();
    return TileMetadata(
      coordinate: coordinate,
      center: center,
      radius: scale * (rectangle.width + rectangle.height) / 2 + height + 2,
      geometricError: levelZeroGeometricError / (1 << coordinate.z),
      decodedBytes: limits.decodedBytes + attribution.length * 2,
      residentBytes: limits.residentBytes,
      children: children.every(_has) ? children : const [],
    );
  }

  Uri _uri(TileCoordinate coordinate) {
    var text = _template;
    for (final entry in {
      'x': '${coordinate.x}',
      'y': '${coordinate.y}',
      'z': '${coordinate.z}',
      'version': version,
    }.entries) {
      text = text.replaceAll('{${entry.key}}', entry.value);
    }
    var uri = _base.resolve(text);
    if (_extensions.isNotEmpty) {
      uri = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'extensions': _extensions.join('-'),
        },
      );
    }
    _policy.validate(_base, uri);
    return uri;
  }

  @override
  Future<TerrainTile> load(
    TileCoordinate coordinate,
    TileLoadContext context,
  ) async {
    context.cancellation.throwIfCancelled();
    _validate(coordinate);
    if (context.sourceIdentity != identity ||
        context.byteBudget < limits.decodedBytes + attribution.length * 2) {
      throw ArgumentError(
        'Terrain load requires its source identity and full reservation.',
      );
    }
    try {
      final resolved = await _read(
        _resolver,
        _uri(coordinate),
        _policy,
        context.cancellation,
        limits.maxEncodedBytes,
        headers: {
          'Accept':
              'application/vnd.quantized-mesh${_extensions.isEmpty ? '' : ';extensions=${_extensions.join('-')}'}',
        },
      );
      final tile = QuantizedMeshDecoder(limits: limits).decode(
        resolved.bytes,
        rectangle: _scheme.getRectangle(coordinate),
        cancellation: context.cancellation,
        skirtDepth: skirtDepth,
        minimumHeight: minimumHeight,
        maximumHeight: maximumHeight,
      );
      context.cancellation.throwIfCancelled();
      _recordAvailability(coordinate, tile.availability);
      return TerrainTile(
        origin: tile.origin,
        geometry: tile.geometry,
        imagery: tile.imagery,
        sampler: tile.sampler,
        imageryRectangle: tile.imageryRectangle,
        waterMask: tile.waterMask,
        availability: tile.availability,
        attributions: attribution.isEmpty ? const [] : [attribution],
      );
    } on LoadCancelled {
      rethrow;
    } on AssetLoadException catch (error) {
      throw _sanitized(error.code);
    } catch (_) {
      context.cancellation.throwIfCancelled();
      throw _sanitized(AssetLoadError.sourceFailed);
    }
  }
}

Future<ResolvedSource> _read(
  ByteSourceResolver resolver,
  Uri uri,
  SourcePolicy policy,
  LoadCancellation cancellation,
  int maxBytes, {
  Map<String, String> headers = const {},
}) async {
  cancellation.throwIfCancelled();
  try {
    policy.validate(uri, uri);
    final context = SourceReadContext(
      maxBytes: maxBytes,
      headers: headers,
      cancellation: cancellation,
      policy: policy,
      onProgress: (_, _) {},
    );
    final source = await resolver.read(uri, context);
    cancellation.throwIfCancelled();
    policy.validate(uri, source.effectiveUri);
    context.reportProgress(source.bytes.length);
    return source;
  } on LoadCancelled {
    rethrow;
  } on AssetLoadException catch (error) {
    cancellation.throwIfCancelled();
    throw _sanitized(error.code);
  } catch (_) {
    cancellation.throwIfCancelled();
    throw _sanitized(AssetLoadError.sourceFailed);
  }
}

AssetLoadException _sanitized(AssetLoadError code) =>
    AssetLoadException(code, 'Terrain source failed (${code.name}).');
Never _invalid() => throw _sanitized(AssetLoadError.invalidData);
Never _unsupported() => throw _sanitized(AssetLoadError.unsupportedFeature);

final class _Availability {
  final int x, y, endX, endY;
  const _Availability(this.x, this.y, this.endX, this.endY);
  bool contains(TileCoordinate tile) =>
      tile.x >= x && tile.x <= endX && tile.y >= y && tile.y <= endY;
}
