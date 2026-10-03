import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

/// A finite synthetic dataset. Transport creates encoded fixture bytes; views
/// always reconstruct geometry and field values from resolver-owned bytes.
class OfflineRepository {
  static const bounds = GeographicRectangle(-.0004, -.0003, .0004, .0003);
  static const credit = 'Zyren synthetic coast · fixture-1 · finite coverage';
  static const gridSize = 33;
  static const gridBytes = 48 + gridSize * gridSize * 8;
  static final keys = {
    for (final id in ['elevation', 'coast', 'bathymetry'])
      id: GeoResourceKey(
        sourceId: 'synthetic-coast',
        sourceVersion: 'fixture-1',
        authorizationPartition: 'public',
        address: id,
        representation: 'scalar-grid-f64',
        decoderVersion: 1,
      ),
  };
  static final plan = GeoRegionPlan(
    region: GeoOfflineRegion(
      id: 'coast-lab',
      sourceVersions: const {'synthetic-coast': 'fixture-1'},
      authorizationPartition: 'public',
      layerIds: const {'terrain', 'coast', 'bathymetry'},
      bounds: bounds,
      minimumLevel: 0,
      maximumLevel: 2,
    ),
    resources: keys.values.map(
      (k) => GeoPlannedResource(key: k, estimatedBytes: gridBytes),
    ),
    coverageComplete: true,
    credits: const [credit],
    maxResources: 3,
    maxBytes: 3 * gridBytes,
  );
  final FileGeoDataStore store;
  final Duration latency;
  bool denySource = false;
  late final GeoResourceResolver resolver;
  late final GeoDataDiagnostics diagnostics;
  late final GeoRegionJob job;
  final _views = <OfflineView>{};
  Future<void>? _closing;
  OfflineRepository._(Directory directory, this.latency)
    : store = FileGeoDataStore(
        directory: directory,
        maxBytes: 2 * 1024 * 1024,
        maxEntries: 16,
      ) {
    resolver = GeoResourceResolver(
      store: store,
      maxResourceBytes: gridBytes,
      fetch: (key, token) => diagnostics.trackSource(key, () async {
        await Future<void>.delayed(latency);
        token.throwIfCancelled();
        if (denySource) throw const GeoDataException(GeoDataError.denied);
        if (!keys.containsValue(key)) {
          throw const GeoDataException(GeoDataError.invalidResponse);
        }
        final bytes = _grid(key.address).encode();
        return GeoResource(
          key: key,
          bytes: bytes,
          fetchedAt: DateTime.now().toUtc(),
          checksum: sha256.convert(bytes).toString(),
          mayPersist: true,
        );
      }),
      metadata: (_) => GeoSourceMetadata(
        sourceId: 'synthetic-coast',
        sourceVersion: 'fixture-1',
        mayPersist: true,
        mayExportOffline: true,
        credits: const [credit],
      ),
    );
    diagnostics = GeoDataDiagnostics(
      resolver: resolver,
      jobs: () => [job],
      inspectTiers: () async {
        final stats = await store.inspect();
        return GeoDataTiers(
          encodedMemoryBytes: 0,
          decodedCpuBytes: _views.fold(0, (n, view) => n! + view.decodedBytes),
          diskPayloadBytes: stats.committedBytes,
          diskMetadataBytes: stats.metadataBytes,
          diskTemporaryBytes: stats.temporaryBytes,
          pinnedBytes: stats.pinnedBytes,
        );
      },
    );
  }
  static Future<OfflineRepository> open(
    Directory directory, {
    Duration latency = const Duration(milliseconds: 350),
  }) async {
    final value = OfflineRepository._(directory, latency);
    final policy = GeoReadPolicy(mode: GeoAccessMode.networkFirst);
    try {
      value.job =
          await GeoRegionJob.restore(
            id: plan.region.id,
            resolver: value.resolver,
            store: value.store,
            downloadPolicy: policy,
          ) ??
          GeoRegionJob(
            resolver: value.resolver,
            store: value.store,
            downloadPolicy: policy,
          );
      return value;
    } catch (_) {
      await value.resolver.close();
      await value.store.close();
      rethrow;
    }
  }

  Future<GeoRegionManifest> download() =>
      job.plan == null ? job.start(plan) : job.resume();
  Future<bool> get hasCoverage async {
    for (final key in keys.values) {
      try {
        await resolver.read(
          key,
          GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
          cancellation: LoadCancellationSource(),
        );
      } on GeoDataException catch (e) {
        if (e.code == GeoDataError.offlineMiss) return false;
        rethrow;
      }
    }
    return true;
  }

  OfflineView createView({required bool offline}) {
    final view = OfflineView(this, offline);
    _views.add(view);
    return view;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    await job.close();
    for (final view in _views.toList()) {
      view.dispose();
    }
    await resolver.close();
    await store.close();
  }

  static GeoScalarGrid _grid(String id) {
    final cells = Float64List(gridSize * gridSize);
    for (var y = 0; y < gridSize; y++) {
      for (var x = 0; x < gridSize; x++) {
        final u = x / (gridSize - 1), v = y / (gridSize - 1);
        final water = u < .5;
        final depth = 20 + 100 * (1 - u) + 20 * v;
        cells[y * gridSize + x] = switch (id) {
          'bathymetry' => water ? depth : double.nan,
          'coast' => water ? 1 : 0,
          _ =>
            water
                ? -depth
                : 450 *
                      math.pow(math.sin((u - .5) * math.pi), 2) *
                      (.25 + .75 * math.pow(math.sin(v * math.pi), 2)),
        };
      }
    }
    return GeoScalarGrid(
      width: gridSize,
      height: gridSize,
      bounds: bounds,
      values: cells,
    );
  }
}

class OfflineView {
  final OfflineRepository repository;
  final bool offline;
  late final policy = GeoReadPolicy(
    mode: offline ? GeoAccessMode.offlineOnly : GeoAccessMode.cacheFirst,
  );
  late final bathymetry = _field(
    'bathymetry',
    'm depth below fixture sea level',
    GeoHeightDatum.meanSeaLevel,
  );
  late final coast = _field(
    'coast',
    'water mask',
    null,
    GeoFieldInterpolation.nearest,
  );
  late final source = StoredFieldTerrain(repository.resolver, policy);
  late final terrain = TerrainExtension(id: 'terrain', source: source);
  late final geo = GeospatialPlugin(
    extensions: [
      GeoDataExtension(
        store: repository.store,
        resolver: repository.resolver,
        diagnostics: repository.diagnostics,
        fields: {'bathymetry': bathymetry, 'coast': coast},
      ),
      terrain,
      GlobeCameraExtension(
        id: 'coast-camera',
        configure: (c) {
          c.camera.position = origin + const Vec3(5200, -3200, 2200);
          c.camera.target = origin;
        },
      ),
    ],
  );
  static const origin = Vec3(6378137, 0, 0);
  final scene = Scene()
    ..background = const Color3(.015, .025, .045)
    ..renderSettings = RenderSettings(hdr: true, toneMapping: ToneMapping.aces)
    ..lightDirection = const Vec3(1, -.4, .7)
    ..ambient = .5;
  final camera = PerspectiveCamera(
    position: origin + const Vec3(5200, -3200, 2200),
    target: origin,
    up: const Vec3(0, 0, 1),
    near: 1,
    far: 2e7,
  );
  OfflineView(this.repository, this.offline);
  int get decodedBytes =>
      bathymetry.decodedBytes + coast.decodedBytes + source.decodedFieldBytes;
  GeoGridFieldSource _field(
    String id,
    String units,
    GeoHeightDatum? datum, [
    GeoFieldInterpolation interpolation = GeoFieldInterpolation.bilinear,
  ]) => GeoGridFieldSource(
    id: id,
    units: units,
    datum: datum,
    key: OfflineRepository.keys[id]!,
    bounds: OfflineRepository.bounds,
    resolver: repository.resolver,
    policy: policy,
    maxCells: OfflineRepository.gridSize * OfflineRepository.gridSize,
    interpolation: interpolation,
  );
  void dispose() {
    bathymetry.dispose();
    coast.dispose();
    source.clear();
    repository._views.remove(this);
  }
}

class StoredFieldTerrain extends ProceduralTerrainSource {
  final GeoResourceResolver resolver;
  final GeoReadPolicy policy;
  Map<String, GeoScalarGrid> _grids = {};
  int get decodedFieldBytes =>
      _grids.values.fold(0, (n, g) => n + g.values.lengthInBytes);
  StoredFieldTerrain(this.resolver, this.policy)
    : super(
        scheme: TilingScheme(width: 1, rectangle: OfflineRepository.bounds),
        segments: 32,
        imagerySize: 64,
        maximumLevel: 2,
        maximumHeight: 450,
      );
  void clear() => _grids = {};
  @override
  TileMetadata describe(TileCoordinate coordinate) {
    final m = super.describe(coordinate);
    return TileMetadata(
      coordinate: coordinate,
      center: m.center,
      radius: m.radius,
      geometricError: m.geometricError,
      decodedBytes: m.decodedBytes + OfflineRepository.credit.length * 2,
      residentBytes: m.residentBytes,
      children: m.children,
    );
  }

  @override
  double heightAt(double u, double v) => _grids['elevation']!.at(
    _coordinate(u, v),
    GeoFieldInterpolation.bilinear,
  )!;
  Geodetic _coordinate(double u, double v) {
    const r = OfflineRepository.bounds;
    return Geodetic(r.west + r.width * u, r.north - r.height * v);
  }

  @override
  Future<TerrainTile> load(
    TileCoordinate coordinate,
    TileLoadContext context,
  ) async {
    final grids = <String, GeoScalarGrid>{};
    for (final entry in OfflineRepository.keys.entries) {
      final value = await resolver.read(
        entry.value,
        policy,
        cancellation: context.cancellation,
        maxBytes: OfflineRepository.gridBytes,
      );
      final grid = GeoScalarGrid.decode(
        value.bytes,
        maxCells: OfflineRepository.gridSize * OfflineRepository.gridSize,
      );
      if (grid.bounds != OfflineRepository.bounds) {
        throw const GeoDataException(GeoDataError.corrupt);
      }
      grids[entry.key] = grid;
    }
    context.cancellation.throwIfCancelled();
    _grids = grids;
    final tile = await super.load(coordinate, context);
    final pixels = Uint8List(imagerySize * imagerySize * 4),
        size = 1 << coordinate.z;
    for (var y = 0; y < imagerySize; y++) {
      for (var x = 0; x < imagerySize; x++) {
        final point = _coordinate(
          (coordinate.x + (x + .5) / imagerySize) / size,
          (size - coordinate.y - 1 + (y + .5) / imagerySize) / size,
        );
        final water =
            grids['coast']!.at(point, GeoFieldInterpolation.nearest) == 1;
        final elevation = grids['elevation']!.at(
          point,
          GeoFieldInterpolation.bilinear,
        )!;
        final depth = grids['bathymetry']!.at(
          point,
          GeoFieldInterpolation.nearest,
        );
        final t = (water ? (depth ?? 0) / 150 : elevation / 450).clamp(
          0.0,
          1.0,
        );
        final a = water ? [56, 178, 183] : [169, 166, 105];
        final b = water ? [16, 47, 88] : [69, 99, 78];
        final contour = (elevation.abs() % 25) < 2;
        final i = (y * imagerySize + x) * 4;
        for (var c = 0; c < 3; c++) {
          pixels[i + c] = ((a[c] * (1 - t) + b[c] * t) * (contour ? .7 : 1))
              .round();
        }
        pixels[i + 3] = 255;
      }
    }
    return TerrainTile(
      origin: tile.origin,
      geometry: tile.geometry,
      imagery: TextureImage.rgba(
        width: imagerySize,
        height: imagerySize,
        pixels: pixels,
        generateMipmaps: true,
      ),
      imageryRectangle: tile.imageryRectangle,
      attributions: const [OfflineRepository.credit],
    );
  }
}
