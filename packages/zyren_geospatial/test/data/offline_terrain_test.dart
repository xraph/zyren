import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'support/offline_fixture.dart';
import 'file_store_process_test.dart' show projectFile;
import 'resolver_test.dart' show error;

void main() {
  test(
    'cold process loads encoded terrain and nested imagery with network forbidden',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-cold-terrain-',
      );
      final payloads = await offlinePayloads();
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 1024 * 1024,
        maxEntries: 32,
      );
      final online = GeoResourceResolver(
        store: store,
        metadata: offlinePermission,
        fetch: (k, _) async => offlineResource(k, payloads[k]!),
      );
      final imageKey = offlineKey('imagery/0/0/0.png');
      final plan = GeoRegionPlan(
        region: GeoOfflineRegion(
          id: 'terrain',
          sourceVersions: {'terrain': '1', 'imagery': '1'},
          authorizationPartition: 'public',
          layerIds: {'terrain', 'imagery'},
          bounds: const GeographicRectangle(-3, -1, -.1, 1),
          minimumLevel: 0,
          maximumLevel: 0,
        ),
        resources: [
          for (final e in payloads.entries)
            GeoPlannedResource(
              key: e.key,
              estimatedBytes: e.value.length,
              dependencies: e.key.address.endsWith('.terrain')
                  ? [imageKey]
                  : [],
            ),
        ],
        coverageComplete: true,
        credits: ['Synthetic fixture'],
      );
      final job = GeoRegionJob(resolver: online, store: store);
      expect((await job.start(plan)).complete, isTrue);
      await job.close();
      await online.close();
      await store.close();
      final child = await Process.run(Platform.resolvedExecutable, [
        '--packages=${projectFile('.dart_tool/package_config.json').path}',
        projectFile(
          'packages/zyren_geospatial/test/data/support/offline_fixture.dart',
        ).path,
        directory.path,
      ]);
      expect(child.exitCode, 0, reason: '${child.stderr}');
      expect(child.stdout, contains('cold-offline-ok'));
      final reopened = FileGeoDataStore(
        directory: directory,
        maxBytes: 1024 * 1024,
        maxEntries: 32,
      );
      var calls = 0;
      final offline = GeoResourceResolver(
        store: reopened,
        metadata: offlinePermission,
        fetch: (_, _) async {
          calls++;
          throw StateError('forbidden');
        },
      );
      final terrain = await offlineTerrain(offline);
      final imagery = TemplateImagerySource(
        baseUri: Uri.parse('geo-resource://fixture/imagery/'),
        template: '{z}/{x}/{y}.png',
        datasetId: 'offline-fixture',
        version: '1',
        tileSize: 2,
        maximumLevel: 1,
        projection: ImageryProjection.geographic,
        attribution: 'Synthetic imagery fixture',
        services: AssetServices(
          resolver: offlineAdapter(offline),
          imageDecoder: const NativeImageDecoder(),
        ),
      );
      final composed = ImageryTerrainSource(
        terrain: terrain,
        layers: [ImageryLayer(imagery)],
        outputSize: 2,
      );
      final tile = await composed.load(
        const TileCoordinate(0, 0, 0),
        offlineContext(composed, const TileCoordinate(0, 0, 0)),
      );
      expect(tile.imagery, isNotNull);
      expect(
        tile.attributions,
        containsAll(['Synthetic terrain fixture', 'Synthetic imagery fixture']),
      );
      await expectLater(
        imagery.load(const TileCoordinate(1, 0, 0), LoadCancellationSource()),
        error(GeoDataError.offlineMiss),
      );
      final reserved = composed.describe(const TileCoordinate(0, 0, 0));
      final scheduler = TileScheduler<TerrainTile>(
        source: composed,
        maximumScreenError: .000001,
        budget: TileBudget(
          maxRequests: 2,
          maxDecodedBytes: reserved.decodedBytes * 6,
          maxResidentBytes: reserved.residentBytes * 6,
          maxSelectedTiles: 32,
        ),
      );
      final camera = PerspectiveCamera(
        position: const Vec3(0, -13000000, 0),
        target: const Vec3(0, -6378137, 0),
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 40000000,
      );
      Future<void> settle() async {
        for (var i = 0; i < 500; i++) {
          scheduler.update(camera, const ViewportMetrics(128, 128));
          if (scheduler.stats.activeRequests == 0) return;
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        fail('Offline selection did not settle.');
      }

      await settle();
      expect(scheduler.visible.keys, contains(const TileCoordinate(0, 0, 0)));
      expect(
        scheduler.failures.any(
          (f) =>
              f.error is GeoDataException &&
              (f.error as GeoDataException).code == GeoDataError.offlineMiss,
        ),
        isTrue,
      );
      camera.position = const Vec3(0, 13000000, 0);
      camera.target = const Vec3(0, 6378137, 0);
      await settle();
      expect(
        scheduler.failures.any(
          (f) => f.coordinate == const TileCoordinate(1, 0, 0),
        ),
        isTrue,
      );
      var reconnectedCalls = 0;
      final reconnected = GeoResourceResolver(
        store: reopened,
        metadata: offlinePermission,
        maxResourceBytes: 1 << 20,
        fetch: (k, _) async {
          reconnectedCalls++;
          final bytes =
              payloads[k] ??
              payloads[offlineKey(
                k.address.endsWith('.png')
                    ? 'imagery/0/0/0.png'
                    : 'terrain/0/0/0.terrain',
              )]!;
          return offlineResource(k, bytes);
        },
      );
      final onlineAdapter = offlineAdapter(
        reconnected,
        policy: GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
      );
      final onlineTerrain = await QuantizedMeshTerrainSource.open(
        uri: Uri.parse('geo-resource://fixture/terrain/layer.json'),
        datasetId: 'offline-fixture',
        resolver: onlineAdapter,
        cancellation: LoadCancellationSource(),
      );
      final onlineImagery = TemplateImagerySource(
        baseUri: Uri.parse('geo-resource://fixture/imagery/'),
        template: '{z}/{x}/{y}.png',
        datasetId: 'offline-fixture',
        version: '1',
        tileSize: 2,
        maximumLevel: 1,
        projection: ImageryProjection.geographic,
        attribution: 'Synthetic imagery fixture',
        services: AssetServices(
          resolver: onlineAdapter,
          imageDecoder: const NativeImageDecoder(),
        ),
      );
      scheduler.replaceSource(
        ImageryTerrainSource(
          terrain: onlineTerrain,
          layers: [ImageryLayer(onlineImagery)],
          outputSize: 2,
        ),
        retainVisible: true,
      );
      camera.position = const Vec3(0, -13000000, 0);
      camera.target = const Vec3(0, -6378137, 0);
      await settle();
      expect(scheduler.failures, isEmpty);
      expect(scheduler.visible.length, greaterThan(1));
      expect(reconnectedCalls, greaterThan(0));
      scheduler.dispose();
      await reconnected.close();
      expect(calls, 0);
      await offline.close();
      await reopened.close();
      await directory.delete(recursive: true);
    },
  );
}
