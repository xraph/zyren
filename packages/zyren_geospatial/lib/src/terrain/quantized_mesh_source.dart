import 'dart:convert';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../tiling.dart';
import '../streaming/tile_source.dart';
import 'terrain_tile.dart';
import 'quantized_mesh_decoder.dart';

/// Static EPSG:4326/TMS quantized-mesh layers over a host-provided resolver.
/// Supply authentication in that resolver. Dataset IDs must contain no secrets.
/// Incomplete sibling coverage stays at the parent until fill tiles are supported.
final class QuantizedMeshTerrainSource implements TerrainSource {
  static int _nextInstance = 0;
  final ByteSourceResolver _resolver;
  final SourcePolicy _policy;
  final Uri _base;
  final String _template;
  final bool _requestNormals;
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
    required bool requestNormals,
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
       _requestNormals = requestNormals,
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
    double minimumHeight = -12000,
    double maximumHeight = 10000,
    double skirtDepth = 50,
    double levelZeroGeometricError = 100000,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9._-]{1,128}$').hasMatch(datasetId) ||
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
      final json = jsonDecode(utf8.decode(resolved.bytes));
      if (json is! Map<String, dynamic>) _invalid();
      for (final (name, expected) in [
        ('format', 'quantized-mesh-1.0'),
        ('scheme', 'tms'),
        ('projection', 'EPSG:4326'),
        ('minzoom', 0),
      ]) {
        if (json.containsKey(name) && json[name] != expected) _unsupported();
      }
      if (json.containsKey('parentUrl') ||
          json.containsKey('metadataAvailability')) {
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
      if (attribution is! String) _invalid();
      final extensions = json['extensions'] ?? <String>[];
      if (extensions is! List || extensions.any((e) => e is! String)) {
        _invalid();
      }
      final availability = json['available'];
      List<List<_Availability>>? available;
      if (json.containsKey('available')) {
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
        requestNormals: extensions.contains('octvertexnormals'),
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

  bool _has(TileCoordinate tile) {
    if (tile.z < 0 ||
        tile.z > maximumLevel ||
        tile.x < 0 ||
        tile.y < 0 ||
        tile.x >= 2 * (1 << tile.z) ||
        tile.y >= 1 << tile.z) {
      return false;
    }
    final availability = _available;
    return availability == null ||
        tile.z < availability.length &&
            availability[tile.z].any((range) => range.contains(tile));
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
      decodedBytes: limits.decodedBytes,
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
    if (_requestNormals) {
      uri = uri.replace(
        queryParameters: {
          ...uri.queryParameters,
          'extensions': 'octvertexnormals',
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
        context.byteBudget < limits.decodedBytes) {
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
      );
      return QuantizedMeshDecoder(limits: limits).decode(
        resolved.bytes,
        rectangle: _scheme.getRectangle(coordinate),
        cancellation: context.cancellation,
        skirtDepth: skirtDepth,
        minimumHeight: minimumHeight,
        maximumHeight: maximumHeight,
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
  int maxBytes,
) async {
  cancellation.throwIfCancelled();
  try {
    policy.validate(uri, uri);
    final context = SourceReadContext(
      maxBytes: maxBytes,
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
