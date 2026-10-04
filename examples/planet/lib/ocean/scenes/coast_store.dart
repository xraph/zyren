import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

/// Owned synthetic coast. All consumers read resolver bytes after publication.
final class OceanLabCoast {
  static const revision = 'ocean-lab-coast-1';
  static const credit =
      'Zyren owned synthetic coast, not geographic survey data';
  static const bounds = GeographicRectangle(-.00002, -.00002, .00002, .00002);
  static const cells = 65;
  static const bytesPerGrid = 48 + cells * cells * 8;
  static final keys = {
    for (final name in ['height', 'depth', 'water'])
      name: GeoResourceKey(
        sourceId: 'ocean-lab-coast',
        sourceVersion: revision,
        authorizationPartition: 'public',
        address: name,
        representation: 'scalar-grid-f64',
        decoderVersion: 1,
      ),
  };
  static final plan = GeoRegionPlan(
    region: GeoOfflineRegion(
      id: 'ocean-lab-coast',
      sourceVersions: const {'ocean-lab-coast': revision},
      authorizationPartition: 'public',
      layerIds: const {'coast', 'bathymetry'},
      bounds: bounds,
      minimumLevel: 0,
      maximumLevel: 0,
    ),
    resources: keys.values.map(
      (k) => GeoPlannedResource(key: k, estimatedBytes: bytesPerGrid),
    ),
    coverageComplete: true,
    credits: const [credit],
    maxResources: 3,
    maxBytes: bytesPerGrid * 3,
  );
  final FileGeoDataStore store;
  late final GeoResourceResolver resolver;
  late final GeoRegionJob job;
  late final GeoGridFieldSource waterGrid;
  late final GeoFieldSource<bool> coverage;
  int fetches = 0;
  OceanLabCoast._(Directory directory, bool allowFixtureGeneration)
    : store = FileGeoDataStore(
        directory: directory,
        maxBytes: 2 * 1024 * 1024,
        maxEntries: 16,
      ) {
    resolver = GeoResourceResolver(
      store: store,
      maxResourceBytes: bytesPerGrid,
      fetch: (key, token) async {
        fetches++;
        token.throwIfCancelled();
        if (!allowFixtureGeneration) {
          throw const GeoDataException(GeoDataError.offlineMiss);
        }
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
      },
      metadata: (_) => GeoSourceMetadata(
        sourceId: 'ocean-lab-coast',
        sourceVersion: revision,
        mayPersist: true,
        mayExportOffline: true,
        credits: const [credit],
      ),
    );
    waterGrid = GeoGridFieldSource(
      id: 'ocean-lab-water',
      units: 'boolean',
      datum: null,
      key: keys['water']!,
      bounds: bounds,
      resolver: resolver,
      policy: GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
      interpolation: GeoFieldInterpolation.nearest,
      maxCells: cells * cells,
    );
    coverage = _WaterCoverage(waterGrid);
  }
  static Future<OceanLabCoast> open(
    Directory directory, {
    bool allowFixtureGeneration = false,
  }) async {
    final repository = OceanLabCoast._(directory, allowFixtureGeneration);
    var jobCreated = false;
    try {
      repository.job =
          await GeoRegionJob.restore(
            id: plan.region.id,
            resolver: repository.resolver,
            store: repository.store,
            downloadPolicy: GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
          ) ??
          GeoRegionJob(
            resolver: repository.resolver,
            store: repository.store,
            downloadPolicy: GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
          );
      jobCreated = true;
      if (allowFixtureGeneration) {
        if (repository.job.plan == null) {
          await repository.job.start(plan);
        } else {
          await repository.job.resume();
        }
      }
      // Opening an incomplete offline repository fails before a scene claims it.
      for (final key in keys.keys) {
        await repository.read(key);
      }
      return repository;
    } catch (_) {
      if (jobCreated) await repository.job.close();
      repository.waterGrid.dispose();
      await repository.resolver.close();
      await repository.store.close();
      rethrow;
    }
  }

  Future<GeoScalarGrid> read(String name) async => GeoScalarGrid.decode(
    (await resolver.read(
      keys[name]!,
      GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
      cancellation: LoadCancellationSource(),
    )).bytes,
  );
  Future<void> close() async {
    waterGrid.dispose();
    await job.close();
    await resolver.close();
    await store.close();
  }

  static GeoScalarGrid _grid(String name) {
    final values = Float64List(cells * cells);
    for (var y = 0; y < cells; y++) {
      for (var x = 0; x < cells; x++) {
        final east = (x / (cells - 1) - .5) * 255,
            north = (y / (cells - 1) - .5) * 253;
        final shore = 30 + 7 * math.sin(north / 25);
        final height = ((east - shore) * .09).clamp(-12.0, 8.0);
        values[y * cells + x] = switch (name) {
          'water' => height < 0 ? 1 : 0,
          'depth' => height < 0 ? -height : 0,
          _ => height,
        };
      }
    }
    return GeoScalarGrid(
      width: cells,
      height: cells,
      bounds: bounds,
      values: values,
    );
  }
}

final class _WaterCoverage implements GeoFieldSource<bool> {
  final GeoGridFieldSource field;
  _WaterCoverage(this.field);
  @override
  String get id => field.id;
  @override
  String get revision => field.revision;
  @override
  String get units => 'boolean';
  @override
  GeoHeightDatum? get datum => null;
  @override
  Future<GeoSample<bool>> sample(Geodetic coordinate, GeoInstant time) async {
    final value = await field.sample(coordinate, time);
    return GeoSample(
      availability: value.availability,
      value: value.value == null ? null : value.value! > .5,
      frameId: value.frameId,
      frameRevision: value.frameRevision,
      sourceRevision: value.sourceRevision,
      units: units,
      time: time,
      age: value.age,
      failure: value.failure,
    );
  }
}
