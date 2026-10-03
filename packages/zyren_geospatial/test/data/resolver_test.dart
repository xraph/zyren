import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'identity_test.dart' show key, resource;

GeoSourceMetadata permission(GeoResourceKey key) => GeoSourceMetadata(
  sourceId: key.sourceId,
  sourceVersion: key.sourceVersion,
  mayPersist: true,
  mayExportOffline: true,
);
Matcher error(GeoDataError code) =>
    throwsA(isA<GeoDataException>().having((e) => e.code, 'code', code));

class DelayedStore implements GeoDataStore {
  final delegate = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
  final entered = Completer<void>(), release = Completer<void>();
  @override
  Future<GeoResource?> read(GeoResourceKey key) => delegate.read(key);
  @override
  Future<bool> write(GeoResource value) async {
    entered.complete();
    await release.future;
    return delegate.write(value);
  }

  @override
  Future<void> remove(GeoResourceKey key) => delegate.remove(key);
  @override
  Future<void> close() => delegate.close();
}

void main() {
  test('authorization failures use redacted denial errors', () async {
    final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
    final resolver = GeoResourceResolver(
      store: store,
      authorize: (_, _) =>
          throw StateError('https://private.example?token=secret'),
      fetch: (k, _) async => resource(k),
    );
    await expectLater(
      resolver.read(
        key(),
        GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
        cancellation: LoadCancellationSource(),
      ),
      error(GeoDataError.denied),
    );
    await resolver.close();
    await store.close();
  });
  test(
    'cache first, strict offline freshness and explicit stale offline policy',
    () async {
      var calls = 0;
      final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
      final now = DateTime.utc(2026, 1, 2);
      final resolver = GeoResourceResolver(
        store: store,
        metadata: permission,
        now: () => now,
        fetch: (k, _) async {
          calls++;
          return resource(k, fetchedAt: now);
        },
      );
      await resolver.read(
        key(),
        GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
        cancellation: LoadCancellationSource(),
      );
      await resolver.read(
        key(),
        GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
        cancellation: LoadCancellationSource(),
      );
      expect(calls, 1);
      await store.write(resource(key()));
      await expectLater(
        resolver.read(
          key(),
          GeoReadPolicy(
            mode: GeoAccessMode.offlineOnly,
            maxAge: const Duration(hours: 1),
          ),
          cancellation: LoadCancellationSource(),
        ),
        error(GeoDataError.stale),
      );
      final stale = await resolver.read(
        key(),
        GeoReadPolicy(
          mode: GeoAccessMode.offlineOnly,
          maxAge: const Duration(hours: 1),
          allowStaleOffline: true,
        ),
        cancellation: LoadCancellationSource(),
      );
      expect(stale.isFreshAt(now, maxAge: const Duration(hours: 1)), isFalse);
      expect(calls, 1);
      await resolver.close();
      await store.close();
    },
  );
  test(
    'unknown persistence permission and online-only reads never populate the store',
    () async {
      final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
      for (final persist in [false, true]) {
        final resolver = GeoResourceResolver(
          store: store,
          metadata: persist ? permission : null,
          fetch: (k, _) async => resource(k),
        );
        await resolver.read(
          key(),
          GeoReadPolicy(
            mode: persist ? GeoAccessMode.onlineOnly : GeoAccessMode.cacheFirst,
          ),
          cancellation: LoadCancellationSource(),
        );
        expect(store.entryCount, 0);
        await resolver.close();
      }
      await store.close();
    },
  );
  test(
    'only transport failures qualify for stale fallback and bounded retry',
    () async {
      final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
      await store.write(resource(key()));
      var calls = 0;
      Object failure = const GeoDataException(GeoDataError.transportFailure);
      final resolver = GeoResourceResolver(
        store: store,
        now: () => DateTime.utc(2026, 2),
        retryDelay: Duration.zero,
        fetch: (_, _) async {
          calls++;
          throw failure;
        },
      );
      final policy = GeoReadPolicy(
        mode: GeoAccessMode.networkFirst,
        maxAge: const Duration(hours: 1),
        allowStaleOnTransportFailure: true,
        maxAttempts: 3,
      );
      final value = await resolver.read(
        key(),
        policy,
        cancellation: LoadCancellationSource(),
      );
      expect(value.bytes, [1, 2, 3]);
      expect(calls, 3);
      failure = StateError('decoder bug');
      await expectLater(
        resolver.read(key(), policy, cancellation: LoadCancellationSource()),
        error(GeoDataError.invalidResponse),
      );
      expect(calls, 4);
      failure = const GeoDataException(GeoDataError.denied);
      await expectLater(
        resolver.read(key(), policy, cancellation: LoadCancellationSource()),
        error(GeoDataError.denied),
      );
      expect(calls, 5);
      await resolver.close();
      await store.close();
    },
  );
  test(
    'removal fences late responses and new requests use a separate generation',
    () async {
      final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
      final entered = Completer<void>(), gate = Completer<GeoResource>();
      var calls = 0;
      final resolver = GeoResourceResolver(
        store: store,
        metadata: permission,
        pool: GeoRequestPool(maxConcurrent: 1),
        fetch: (k, _) {
          if (++calls == 1) {
            entered.complete();
            return gate.future;
          }
          return Future.value(resource(k, bytes: [9]));
        },
      );
      final first = resolver.read(
        key(),
        GeoReadPolicy(mode: GeoAccessMode.networkFirst),
        cancellation: LoadCancellationSource(),
      );
      await entered.future;
      final cancelled = expectLater(first, error(GeoDataError.cancelled));
      await resolver.remove(key());
      await cancelled;
      final second = resolver.read(
        key(),
        GeoReadPolicy(mode: GeoAccessMode.networkFirst),
        cancellation: LoadCancellationSource(),
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      gate.complete(resource(key()));
      expect((await second).bytes, [9]);
      expect((await store.read(key()))!.bytes, [9]);
      await resolver.close();
      await store.close();
    },
  );
  test(
    'removal drains an accepted write before deleting its resource',
    () async {
      final store = DelayedStore();
      final resolver = GeoResourceResolver(
        store: store,
        metadata: permission,
        fetch: (k, _) async => resource(k),
      );
      final pending = resolver.read(
        key(),
        GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
        cancellation: LoadCancellationSource(),
      );
      await store.entered.future;
      final cancelled = expectLater(pending, error(GeoDataError.cancelled));
      var removed = false;
      final removal = resolver.remove(key()).then((_) => removed = true);
      await cancelled;
      expect(removed, isFalse);
      store.release.complete();
      await removal;
      expect(await store.read(key()), isNull);
      await resolver.close();
      await store.close();
    },
  );
  test(
    'authorization is checked again before cached bytes are delivered',
    () async {
      final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
      await store.write(resource(key(partition: 'tenant')));
      var authorizations = 0, transports = 0;
      final resolver = GeoResourceResolver(
        store: store,
        authorize: (_, _) => ++authorizations == 1,
        fetch: (k, _) async {
          transports++;
          return resource(k);
        },
      );
      await expectLater(
        resolver.read(
          key(partition: 'tenant'),
          GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
          cancellation: LoadCancellationSource(),
        ),
        error(GeoDataError.denied),
      );
      expect(transports, 0);
      await resolver.close();
      await store.close();
    },
  );
}
