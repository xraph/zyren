import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'identity_test.dart' show key, resource;

void main() {
  test('offline misses cannot touch transport', () async {
    var calls = 0;
    final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
    final resolver = GeoResourceResolver(
      store: store,
      fetch: (key, token) async {
        calls++;
        throw StateError('transport is forbidden');
      },
    );
    await expectLater(
      resolver.read(
        key(),
        GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
        cancellation: LoadCancellationSource(),
      ),
      throwsA(
        isA<GeoDataException>().having(
          (e) => e.code,
          'code',
          GeoDataError.offlineMiss,
        ),
      ),
    );
    expect(calls, 0);
    await resolver.close();
    await store.close();
  });
  test(
    'denial never becomes stale success and protected cache reads require current permission',
    () async {
      final store = MemoryGeoDataStore(maxBytes: 1024, maxEntries: 4);
      await store.write(resource(key()));
      await store.write(resource(key(partition: 'tenant')));
      final resolver = GeoResourceResolver(
        store: store,
        now: () => DateTime.utc(2026, 2),
        fetch: (_, _) async => throw GeoDataException(GeoDataError.denied),
      );
      await expectLater(
        resolver.read(
          key(),
          GeoReadPolicy(
            mode: GeoAccessMode.networkFirst,
            maxAge: const Duration(hours: 1),
            allowStaleOnTransportFailure: true,
          ),
          cancellation: LoadCancellationSource(),
        ),
        throwsA(
          isA<GeoDataException>().having(
            (e) => e.code,
            'code',
            GeoDataError.denied,
          ),
        ),
      );
      await expectLater(
        resolver.read(
          key(partition: 'tenant'),
          GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
          cancellation: LoadCancellationSource(),
        ),
        throwsA(
          isA<GeoDataException>().having(
            (e) => e.code,
            'code',
            GeoDataError.denied,
          ),
        ),
      );
      await resolver.close();
      await store.close();
    },
  );
}
