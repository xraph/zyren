import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'coast_store.dart';

/// A pinned NOAA region. Imported assets enter the same D3 store as downloads.
final class OceanEarthCoast implements OceanCoastSource {
  static const revision = 'noaa-etopo2022-monterey-1';
  static const credit =
      'NOAA NCEI ETOPO 2022 · Monterey Bay · 15 arc-seconds · Not for navigation';
  static const assetDirectory = 'assets/ocean/monterey';
  static const names = ['height', 'depth', 'water', 'geoid'];
  @override
  String get attribution => credit;
  @override
  String get sourceId => 'noaa-etopo2022-monterey';
  @override
  String get dataRevision => revision;
  @override
  Geodetic get origin => Geodetic.degrees(-121.94, 36.65, seaLevel);
  final double seaLevel;
  final GeographicRectangle bounds;
  final FileGeoDataStore store;
  final Map<String, GeoResourceKey> keys;
  final Map<String, String> checksums;
  late final GeoResourceResolver resolver;
  late final GeoRegionPlan plan;
  late final GeoRegionJob job;
  late final GeoGridFieldSource waterGrid;
  @override
  late final GeoFieldSource<bool> coverage;
  int fetches = 0;

  OceanEarthCoast._(Directory directory, Map<String, dynamic> metadata)
    : seaLevel = (metadata['seaLevelEllipsoidMetres'] as num).toDouble(),
      bounds = GeographicRectangle.fromList(
        (metadata['boundsRadians'] as List)
            .cast<num>()
            .map((n) => n.toDouble())
            .toList(),
      ),
      checksums = {
        for (final name in names)
          name: metadata['resources'][name]['sha256'] as String,
      },
      keys = {
        for (final name in names)
          name: GeoResourceKey(
            sourceId: 'noaa-etopo2022-monterey',
            sourceVersion: revision,
            authorizationPartition: 'public',
            address: name,
            representation: 'scalar-grid-f64',
            decoderVersion: 1,
          ),
      },
      store = FileGeoDataStore(
        directory: directory,
        maxBytes: 2 * 1024 * 1024,
        maxEntries: 16,
      );

  static Future<OceanEarthCoast> open(
    Directory directory, {
    required String manifest,
    Future<Uint8List> Function(String name)? loadBundle,
  }) async {
    final metadata = jsonDecode(manifest) as Map<String, dynamic>;
    if (metadata['version'] != 1 ||
        metadata['revision'] != revision ||
        metadata['width'] != 96 ||
        metadata['height'] != 72 ||
        metadata['sourceDatum'] != 'EGM2008' ||
        metadata['terrainDatum'] != 'WGS84 ellipsoid') {
      throw const FormatException('Unknown NOAA region format or datum.');
    }
    const bytesPerGrid = 48 + 96 * 72 * 8;
    final result = OceanEarthCoast._(directory, metadata);
    var jobCreated = false, resolverCreated = false, fieldCreated = false;
    try {
      for (final name in names) {
        if (metadata['resources'][name]['bytes'] != bytesPerGrid ||
            !RegExp(r'^[0-9a-f]{64}$').hasMatch(result.checksums[name]!)) {
          throw const FormatException('Invalid NOAA region resource.');
        }
      }
      result.resolver = GeoResourceResolver(
        store: result.store,
        maxResourceBytes: bytesPerGrid,
        fetch: (key, cancellation) async {
          result.fetches++;
          cancellation.throwIfCancelled();
          if (loadBundle == null) {
            throw const GeoDataException(GeoDataError.offlineMiss);
          }
          if (result.keys[key.address] != key) {
            throw const GeoDataException(GeoDataError.invalidResponse);
          }
          final bytes = await loadBundle(key.address);
          cancellation.throwIfCancelled();
          if (bytes.length != bytesPerGrid ||
              sha256.convert(bytes).toString() !=
                  result.checksums[key.address]) {
            throw const GeoDataException(GeoDataError.corrupt);
          }
          return GeoResource(
            key: key,
            bytes: bytes,
            fetchedAt: DateTime.utc(2026, 10, 4),
            checksum: result.checksums[key.address]!,
            mayPersist: true,
          );
        },
        metadata: (_) => GeoSourceMetadata(
          sourceId: 'noaa-etopo2022-monterey',
          sourceVersion: revision,
          mayPersist: true,
          mayExportOffline: true,
          credits: const [
            credit,
            'https://doi.org/10.25921/fd45-gt74',
            'CC0-1.0',
          ],
        ),
      );
      resolverCreated = true;
      result.waterGrid = GeoGridFieldSource(
        id: 'monterey-water',
        units: 'boolean',
        datum: null,
        key: result.keys['water']!,
        bounds: result.bounds,
        resolver: result.resolver,
        policy: GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
        interpolation: GeoFieldInterpolation.nearest,
        maxCells: 96 * 72,
      );
      result.coverage = OceanGridWaterCoverage(result.waterGrid);
      fieldCreated = true;
      result.plan = GeoRegionPlan(
        region: GeoOfflineRegion(
          id: revision,
          sourceVersions: const {'noaa-etopo2022-monterey': revision},
          authorizationPartition: 'public',
          layerIds: const {'coast', 'bathymetry', 'geoid'},
          bounds: result.bounds,
          minimumLevel: 0,
          maximumLevel: 0,
        ),
        resources: result.keys.values.map(
          (key) => GeoPlannedResource(key: key, estimatedBytes: bytesPerGrid),
        ),
        coverageComplete: true,
        credits: const [credit, 'CC0-1.0'],
        maxResources: 4,
        maxBytes: bytesPerGrid * 4,
      );
      result.job =
          await GeoRegionJob.restore(
            id: revision,
            resolver: result.resolver,
            store: result.store,
            downloadPolicy: GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
          ) ??
          GeoRegionJob(
            resolver: result.resolver,
            store: result.store,
            downloadPolicy: GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
          );
      jobCreated = true;
      if (loadBundle != null) {
        if (result.job.plan == null) {
          await result.job.start(result.plan);
        } else {
          await result.job.resume();
        }
      }
      if (result.job.plan?.digest != result.plan.digest) {
        throw const GeoDataException(GeoDataError.offlineMiss);
      }
      for (final name in names) {
        await result.read(name);
      }
      return result;
    } catch (_) {
      if (jobCreated) await result.job.close();
      if (fieldCreated) result.waterGrid.dispose();
      if (resolverCreated) await result.resolver.close();
      await result.store.close();
      rethrow;
    }
  }

  @override
  Future<GeoScalarGrid> read(String name) async {
    final key = keys[name];
    if (key == null) throw ArgumentError.value(name, 'name');
    final resource = await resolver.read(
      key,
      GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
      cancellation: LoadCancellationSource(),
    );
    if (sha256.convert(resource.bytes).toString() != checksums[name]) {
      throw const GeoDataException(GeoDataError.corrupt);
    }
    final grid = GeoScalarGrid.decode(resource.bytes, maxCells: 96 * 72);
    if (grid.width != 96 ||
        grid.height != 72 ||
        grid.bounds.toList().toString() != bounds.toList().toString()) {
      throw const GeoDataException(GeoDataError.corrupt);
    }
    return grid;
  }

  @override
  Future<void> close() async {
    waterGrid.dispose();
    await job.close();
    await resolver.close();
    await store.close();
  }
}
