# Geospatial offline data implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking. Execute sequentially in this chat, as selected on 2026-10-03.

**Goal:** Persist bounded geographic resources and verified offline regions across process restarts.

**Architecture:** Put geographic identity, policy and region manifests in geospatial. Wrap existing bounded source resolvers and decoded caches. Store encoded bytes separately from CPU recipes and GPU resources, with a native file implementation and a substitutable public store.

**Tech Stack:** Dart from Flutter 3.47.5/FVM, dart:io, SHA-256, AssetServices and ByteSourceResolver.

**Spec:** [Platform caching and offline design](design.md). Depends on [foundation F1-F4](01-foundation-plan.md).

## Global constraints

- Rendering remains native Metal, Vulkan or DX12.
- The core stays independent of geospatial, Flutter, provider APIs and simulation domains.
- Signed URLs and credentials are transport details, not public keys or persisted diagnostic labels.
- `offlineOnly` cannot invoke a network resolver, including for redirects or nested resources.
- Pinned regions are never silently evicted.
- Work on the active branch, preserve concurrent work and commit exact owned paths. No pushes, merges or attribution trailers.
- Apply `rex-voice` and embedded `humanizer` to shipped prose. Use the workspace FVM SDK.

## Review focus

- The same public dataset ID in two authorization partitions must never share protected bytes: D1.
- A cold offline read must not request a missing nested resource over the network: D1 and D3.
- Disk exhaustion while publishing a pinned region must preserve the previous complete manifest: D2 and D3.
- Cancellation, late completion and concurrent writers must not revive removed data: D1 and D2.
- Fresh transport denial must not become a successful stale-cache read: D1.

## Task 1: D1 Resource identity, policy and coalesced reads

Files in `packages/zyren_geospatial`:

- Create `lib/src/data/resource_key.dart`, `policy.dart`, `store.dart`,
  `request_pool.dart` and `resolver.dart`.
- Export pure APIs in `lib/zyren_geospatial.dart`.
- Test `test/data/policy_test.dart`, `identity_test.dart`, `request_pool_test.dart`.

Public contract:

```dart
GeoResourceKey({required String sourceId, required String sourceVersion,
  required String authorizationPartition, required String address,
  required String representation, required int decoderVersion,
  String? projection, String? timeSlice, String? derivation});
String get digest; // Hash of canonical typed fields, never a transport URL.
enum GeoAccessMode { onlineOnly, cacheFirst, networkFirst, offlineOnly }
GeoReadPolicy({required GeoAccessMode mode, Duration? maxAge,
  bool allowStaleOnTransportFailure = false});
GeoResource({required GeoResourceKey key, required Uint8List bytes,
  required DateTime fetchedAt, required String checksum,
  DateTime? expiresAt, String? mediaType});
abstract interface class GeoDataStore {
  Future<GeoResource?> read(GeoResourceKey key);
  Future<bool> write(GeoResource resource);
  Future<void> remove(GeoResourceKey key);
  Future<void> close();
}
GeoResourceResolver({required GeoDataStore store,
  required Future<GeoResource> Function(GeoResourceKey, LoadCancellation) fetch});
Future<GeoResource> read(GeoResourceKey key, GeoReadPolicy policy,
  {required LoadCancellation cancellation});
```

`MemoryGeoDataStore(maxBytes, maxEntries)` is the bounded test/reference store.
Define `GeoDataException` with codes `offlineMiss`, `denied`, `corrupt`,
`stale`, `cancelled`, `budgetExceeded`, `closed` and `transportFailure`.
Source metadata separately declares `mayPersist`, `mayExportOffline` and credits;
the resolver refuses disallowed writes and regions.

- [x] Write and run the offline regression:

```dart
test('offline misses cannot touch transport', () async {
  var calls = 0;
  final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
  final resolver = GeoResourceResolver(store: store, fetch: (key, token) async {
    calls++;
    throw StateError('transport is forbidden');
  });
  final key = GeoResourceKey(sourceId: 'sea', sourceVersion: '1',
    authorizationPartition: 'public', address: 'mask/0/0/0',
    representation: 'r8', decoderVersion: 1);
  await expectLater(resolver.read(key,
    GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
    cancellation: LoadCancellationSource()), throwsA(isA<GeoDataException>()));
  expect(calls, 0);
  await store.close();
});
```

- [x] Implement policy dispatch before constructing any transport URI:

```dart
if (policy.mode == GeoAccessMode.offlineOnly) {
  final cached = await store.read(key);
  if (cached == null) throw GeoDataException(GeoDataError.offlineMiss);
  return validateCached(cached, policy);
}
```

  `GeoDataError` is the enum containing the codes above. Internal
  `validateCached(GeoResource, GeoReadPolicy) -> GeoResource` verifies checksum,
  freshness and current authorization policy. Use structured canonical fields,
  length limits and immutable bytes. Do not persist signed transport locations.
- [x] Coalesce requests by complete key and policy-compatible generation. Give
  each consumer a cancellation token; the physical slot remains reserved until
  work settles. Tests cover one of two consumers cancelling, all cancelling,
  source replacement, late failures and retry bounds. Denial never enters the
  stale transport-failure branch.
- [x] Run the data tests and analyzer. Check key separation for auth partition,
  projection, decoder revision, time and source version.
- [x] Commit `feat(geospatial): add governed geographic resource reads`.

## Task 2: D2 Durable file store and admission

Files:

- Create `lib/offline.dart`, `lib/src/data/file_store.dart`,
  `file_index.dart`, `file_lock.dart` and `integrity.dart` in geospatial.
- Modify its `pubspec.yaml` for `crypto` only if no suitable dependency exists.
- Test `test/data/file_store_test.dart`, `file_store_process_test.dart` and
  `test/data/support/store_process.dart`.

Contract: `FileGeoDataStore({required Directory directory, required int maxBytes,
required int maxEntries}) implements GeoDataStore`. Add
`inspect() -> Future<GeoStoreStats>` where stats distinguish committed,
temporary, pinned and leased bytes. `pin(String manifestId, Set<String> digests)`
and `unpin(String manifestId)` maintain reference counts, not one global boolean.

- [x] Test cold restart, then the same bytes after eviction pressure:

```dart
final first = FileGeoDataStore(directory: directory,
  maxBytes: 4096, maxEntries: 8);
expect(await first.write(resource), isTrue);
await first.close();
final restarted = FileGeoDataStore(directory: directory,
  maxBytes: 4096, maxEntries: 8);
expect((await restarted.read(resource.key))!.bytes, resource.bytes);
await restarted.close();
```

  The test creates `directory` with `Directory.systemTemp.createTemp()` and
  `resource` with the D1 constructor, using a SHA-256 checksum of `[1,2,3]`.
  Delete only that owned directory in test teardown.
- [x] Use process locks, digest-named immutable blobs and a journaled metadata
  transaction. Reserve temporary, final and manifest overhead before writes.
  Flush staging files and publish by rename, then commit references. Recovery
  discards orphan staging data and rebuilds indexes without trusting incomplete
  manifests. Follow the locking lessons in existing `FilePipelineCache`, without
  importing its model bundle semantics.

```dart
final digest = sha256.convert(resource.bytes).toString();
if (digest != resource.checksum) {
  throw GeoDataException(GeoDataError.corrupt);
}
```

- [x] Add fault-injection tests at staging, blob publication and manifest commit.
  Use two child Dart processes for locking tests. Cover corruption, path traversal,
  symlink escape from the owned store, simultaneous readers, failed lock acquisition,
  cancellation and exhausted budgets with every existing entry pinned.
- [x] Run all D1/D2 tests and the package analyzer. Check close waits for accepted
  operations and that invalidated generations cannot write after removal.
- [x] Commit `feat(geospatial): persist bounded offline resource storage`.

## Task 3: D3 Complete offline regions and live layer integration

Files:

- Create `lib/src/data/region.dart`, `region_job.dart`, `coverage.dart`,
  `source_catalog.dart` and `terrain_resolver.dart`.
- Modify terrain/imagery source construction to accept the shared resource policy
  through existing transport injection, preserving direct constructors.
- Test `test/data/region_test.dart`, `offline_terrain_test.dart` and `coverage_test.dart`.

Contract: `GeoOfflineRegion` fixes ID, source versions, selected layer IDs,
geographic bounds, min/max detail and optional time interval. A region planner
returns `GeoRegionPlan` with bounded resource count, estimated bytes, credits and
required dependency keys. `GeoRegionJob.start(plan)`, `cancel()`, `resume()` and
`verify()` return/maintain immutable progress with explicit missing resources.
`GeoRegionManifest.complete` is true only after every required key verifies.

- [x] Build a local fixture with terrain, imagery and one missing child asset.
  The following assertion belongs after starting that job:

```dart
final result = await job.verify();
expect(result.complete, isFalse);
expect(result.missingKeys, contains(childKey));
expect(result.verifiedKeys, isNot(contains(childKey)));
```

  `job` is a `GeoRegionJob`; `childKey` is the deliberately absent D1 key.
  `verify()` returns `GeoRegionManifest` with the three shown fields.
- [x] Resolve nested dependencies within the same access policy and scope.
  Enumerators must declare resource bounds and fail a global/unbounded request
  before downloads start. Antimeridian coverage uses split longitude intervals;
  polar coverage cannot be inferred from Mercator tiles. Unknown source coverage
  remains incomplete. Credentials remain in caller transport.
- [x] Use a manifest state machine with persisted jobs:

```dart
enum GeoRegionJobState { planned, downloading, paused, verifying, complete, failed }
```

  Completing publishes pins and manifest together. Cancelling retains only the
  resumable verified resources allowed by policy. Replacing a region keeps the
  previous complete manifest readable until its replacement verifies.
- [x] Test process restart with a transport that throws on every call, then pan
  within coverage and outside it. Verify existing parent fallback, explicit
  offline misses, retry after reconnection and visible layer attribution.
- [x] Commit `feat(geospatial): download and verify offline regions`.

## Task 4: D4 Ocean-data and model-bundle adapters, diagnostics and example

Files:

- Create `lib/src/data/field_source.dart` and `examples/planet/lib/layers/offline.dart`.
- Add a model adapter in `packages/zyren_pipeline/lib/geospatial.dart` only if its
  dependency direction remains valid; otherwise inject it through `GeoDataStore`
  at the application boundary without adding a reverse import.
- Test `test/data/field_source_test.dart` and the example's offline integration test.
- Update geospatial README and qualification records.

Contract: `GeoFieldSource<T>` declares ID, revision, units, datum and
`sample(Geodetic coordinate, GeoInstant time) -> Future<GeoSample<T>>`.
Ocean coast coverage and bathymetry use this service; a file does not become a
global coast dataset merely because it can be loaded. Model bundles retain the
existing `FilePipelineCache` ownership and are referenced by verified version.

- [x] Use a synthetic coast split and known bathymetric ramp as fixtures, with
  explicit provenance and finite coverage. Test field queries after closing and
  reopening the data store with no transport.
- [x] Register scoped data diagnostics in the existing geospatial registry:

```dart
final registration = context.registry.provide(
  GeoServiceKey<GeoDataStore>('geospatial.data', 1), store);
context.sceneContext.scope.keep(registration);
```

  Report bytes by tier, source failures and region completeness; never report
  payload estimates as physical GPU residency.
- [x] Add compact application controls for download, cancellation, offline-only
  mode and retry. Verify that every action updates real job state and survives a
  restart. Keep widgets outside the geospatial package.
- [x] Run affected tests, native offline terrain checks and desktop/narrow example
  checks. Record provider-specific permissions and missing global data separately.
- [x] Commit `feat(geospatial): integrate offline fields and diagnostics`.

## Completion gate

A restart with networking disabled must load a verified region and fail clearly
outside it. Model textures, masks and metadata follow the same policy. No warm
in-memory cache, generated terrain demo or saved route line counts as this gate.
