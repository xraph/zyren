import 'dart:io';
import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'identity_test.dart' show key, resource;
import 'resolver_test.dart' show permission, error;

GeoResourceKey namedKey(String version, String address) => GeoResourceKey(
  sourceId: 'sea',
  sourceVersion: version,
  authorizationPartition: 'public',
  address: address,
  representation: 'r8',
  decoderVersion: 1,
);
GeoRegionPlan fixturePlan(
  String version, {
  int count = 2,
  bool coverage = true,
}) => GeoRegionPlan(
  region: GeoOfflineRegion(
    id: 'coast',
    sourceVersions: {'sea': version},
    authorizationPartition: 'public',
    layerIds: {'terrain'},
    bounds: const GeographicRectangle(0, 0, .1, .1),
    minimumLevel: 0,
    maximumLevel: 0,
  ),
  resources: [
    for (var i = 0; i < count; i++)
      GeoPlannedResource(key: namedKey(version, 'part/$i'), estimatedBytes: 3),
  ],
  coverageComplete: coverage,
);

void main() {
  test(
    'missing nested resource prevents publication of a complete region',
    () async {
      final directory = await Directory.systemTemp.createTemp('zyren-region-');
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 65536,
        maxEntries: 8,
      );
      final parent = key();
      final region = GeoOfflineRegion(
        id: 'coast',
        sourceVersions: {'sea': '1'},
        authorizationPartition: 'public',
        layerIds: {'terrain'},
        bounds: const GeographicRectangle(0, 0, .1, .1),
        minimumLevel: 0,
        maximumLevel: 0,
      );
      // Child resources may use a separately versioned source, never a hidden URL.
      final childKey = GeoResourceKey(
        sourceId: 'imagery',
        sourceVersion: '1',
        authorizationPartition: 'public',
        address: 'tile/0',
        representation: 'rgba',
        decoderVersion: 1,
      );
      final plan = GeoRegionPlan(
        region: GeoOfflineRegion(
          id: region.id,
          sourceVersions: {'sea': '1', 'imagery': '1'},
          authorizationPartition: 'public',
          layerIds: region.layerIds,
          bounds: region.bounds,
          minimumLevel: 0,
          maximumLevel: 0,
        ),
        resources: [
          GeoPlannedResource(
            key: parent,
            estimatedBytes: 3,
            dependencies: [childKey],
          ),
          GeoPlannedResource(key: childKey, estimatedBytes: 3),
        ],
        coverageComplete: true,
      );
      final failing = GeoResourceResolver(
        store: store,
        metadata: permission,
        fetch: (k, _) async {
          if (k == childKey) {
            throw const GeoDataException(GeoDataError.transportFailure);
          }
          return resource(k);
        },
      );
      final job = GeoRegionJob(resolver: failing, store: store);
      await job.start(plan);
      final result = await job.verify();
      expect(result.complete, isFalse);
      expect(result.missingKeys, contains(childKey));
      expect(result.verifiedKeys, isNot(contains(childKey)));
      expect(await store.readManifest('region.coast'), isNull);
      await job.close();
      await failing.close();
      await store.close();
      await directory.delete(recursive: true);
    },
  );
  test('complete regions verify on cold restart without transport', () async {
    final directory = await Directory.systemTemp.createTemp(
      'zyren-region-cold-',
    );
    var store = FileGeoDataStore(
      directory: directory,
      maxBytes: 65536,
      maxEntries: 8,
    );
    var resolver = GeoResourceResolver(
      store: store,
      metadata: permission,
      fetch: (k, _) async => resource(k),
    );
    final job = GeoRegionJob(resolver: resolver, store: store);
    expect((await job.start(fixturePlan('1'))).complete, isTrue);
    expect(await store.readManifest('job.coast'), isNull);
    await job.close();
    await resolver.close();
    await store.close();
    var calls = 0;
    store = FileGeoDataStore(
      directory: directory,
      maxBytes: 65536,
      maxEntries: 8,
    );
    resolver = GeoResourceResolver(
      store: store,
      metadata: permission,
      fetch: (_, _) async {
        calls++;
        throw StateError('transport forbidden');
      },
    );
    final restored = await GeoRegionJob.restore(
      id: 'coast',
      resolver: resolver,
      store: store,
    );
    expect(restored!.progress.state, GeoRegionJobState.complete);
    expect((await restored.verify()).complete, isTrue);
    await expectLater(
      resolver.read(
        namedKey('1', 'outside'),
        GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
        cancellation: LoadCancellationSource(),
      ),
      error(GeoDataError.offlineMiss),
    );
    expect(calls, 0);
    await restored.close();
    await resolver.close();
    await store.close();
    await directory.delete(recursive: true);
  });
  test(
    'cancellation persists verified progress and restart resumes missing resources',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-region-resume-',
      );
      var store = FileGeoDataStore(
        directory: directory,
        maxBytes: 65536,
        maxEntries: 8,
      );
      final entered = Completer<void>(), release = Completer<void>();
      var resolver = GeoResourceResolver(
        store: store,
        metadata: permission,
        fetch: (k, _) async {
          if (k.address == 'part/1') {
            entered.complete();
            await release.future;
          }
          return resource(k);
        },
      );
      final job = GeoRegionJob(resolver: resolver, store: store);
      final run = job.start(fixturePlan('1'));
      await entered.future;
      await job.cancel();
      expect((await run).complete, isFalse);
      expect(job.progress.state, GeoRegionJobState.paused);
      expect(job.progress.verifiedResources, 1);
      release.complete();
      await job.close();
      await resolver.close();
      await store.close();
      store = FileGeoDataStore(
        directory: directory,
        maxBytes: 65536,
        maxEntries: 8,
      );
      final fetched = <GeoResourceKey>[];
      resolver = GeoResourceResolver(
        store: store,
        metadata: permission,
        fetch: (k, _) async {
          fetched.add(k);
          return resource(k);
        },
      );
      final restored = await GeoRegionJob.restore(
        id: 'coast',
        resolver: resolver,
        store: store,
      );
      expect(restored!.progress.state, GeoRegionJobState.paused);
      expect(fetched, isEmpty);
      expect((await restored.resume()).complete, isTrue);
      expect(fetched, [namedKey('1', 'part/1')]);
      await restored.close();
      await resolver.close();
      await store.close();
      await directory.delete(recursive: true);
    },
  );
  test(
    'failed replacement and manifest publication preserve the complete region',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-region-replace-',
      );
      late GeoRegionJob job;
      var failPublish = false, failFetch = false;
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 65536,
        maxEntries: 8,
        onWriteStage: (stage) {
          if (failPublish &&
              job.progress.state == GeoRegionJobState.verifying &&
              stage == GeoStoreWriteStage.indexStaged) {
            throw StateError('disk full');
          }
        },
      );
      final resolver = GeoResourceResolver(
        store: store,
        metadata: permission,
        fetch: (k, _) async {
          if (failFetch && k.sourceVersion == '2' && k.address == 'part/1') {
            throw const GeoDataException(GeoDataError.transportFailure);
          }
          return resource(k);
        },
      );
      job = GeoRegionJob(resolver: resolver, store: store);
      await job.start(fixturePlan('1'));
      final original = await store.readManifest('region.coast');
      failFetch = true;
      expect((await job.start(fixturePlan('2'))).complete, isFalse);
      expect(
        (await store.readManifest('region.coast'))!.revision,
        original!.revision,
      );
      failFetch = false;
      failPublish = true;
      await expectLater(job.resume(), error(GeoDataError.transportFailure));
      expect(
        (await store.readManifest('region.coast'))!.revision,
        original.revision,
      );
      for (final value in fixturePlan('1').resources) {
        expect(await store.read(value.key), isNotNull);
      }
      failPublish = false;
      expect((await job.resume()).complete, isTrue);
      expect(
        (await store.readManifest('region.coast'))!.revision,
        greaterThan(original.revision),
      );
      expect((await store.inspect()).pinnedBytes, 6);
      await job.close();
      await resolver.close();
      await store.close();
      await directory.delete(recursive: true);
    },
  );
  test(
    'manifest revisions reject stale writers without changing pins',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-region-cas-',
      );
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 65536,
        maxEntries: 8,
      );
      await store.write(resource(key()));
      final first = await store.commitManifest(
        'region.a',
        {'value': 1},
        {key().digest},
        expectedRevision: null,
      );
      final second = await store.commitManifest(
        'region.a',
        {'value': 2},
        {key().digest},
        expectedRevision: first.revision,
      );
      await expectLater(
        store.commitManifest(
          'region.a',
          {'value': 3},
          {},
          expectedRevision: first.revision,
        ),
        error(GeoDataError.conflict),
      );
      expect((await store.readManifest('region.a'))!.revision, second.revision);
      expect((await store.inspect()).pinnedBytes, 3);
      await store.close();
      await directory.delete(recursive: true);
    },
  );
  test(
    'cancellation drops job pins after export permission is revoked',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'zyren-region-permission-',
      );
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 65536,
        maxEntries: 8,
      );
      var allowed = true;
      final entered = Completer<void>(), release = Completer<void>();
      final resolver = GeoResourceResolver(
        store: store,
        metadata: (k) => GeoSourceMetadata(
          sourceId: k.sourceId,
          sourceVersion: k.sourceVersion,
          mayPersist: allowed,
          mayExportOffline: allowed,
        ),
        fetch: (k, _) async {
          if (k.address == 'part/1') {
            entered.complete();
            await release.future;
          }
          return resource(k);
        },
      );
      final job = GeoRegionJob(resolver: resolver, store: store);
      final pending = job.start(fixturePlan('1'));
      await entered.future;
      allowed = false;
      await job.cancel();
      expect((await pending).complete, isFalse);
      expect(job.progress.verifiedResources, 0);
      expect((await store.inspect()).pinnedBytes, 0);
      release.complete();
      await job.close();
      await resolver.close();
      await store.close();
      await directory.delete(recursive: true);
    },
  );
}
