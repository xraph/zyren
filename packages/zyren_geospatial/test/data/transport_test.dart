import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'identity_test.dart' show key, resource;
import 'resolver_test.dart' show error, permission;

class Source implements ByteSourceResolver {
  final Future<ResolvedSource> Function(Uri, SourceReadContext) handle;
  Source(this.handle);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) =>
      handle(uri, context);
}

void main() {
  test(
    'freshness includes response age and rejects ambiguous cache metadata',
    () async {
      final now = DateTime.utc(2026, 10, 3, 12);
      var headers = <String, String>{
        'cache-control': 'public, max-age=120',
        'age': '30',
        'date': 'Sat, 03 Oct 2026 11:59:00 GMT',
      };
      final transport = GeoByteSourceTransport(
        source: Source(
          (uri, _) async => ResolvedSource(
            effectiveUri: uri,
            bytes: Uint8List.fromList([1]),
            headers: headers,
          ),
        ),
        now: () => now,
        locate: (_) => GeoTransportLocation(
          uri: Uri.parse('https://example.test/a'),
          maxAge: const Duration(minutes: 5),
        ),
      );
      final result = await transport.fetch(key(), LoadCancellationSource());
      expect(result.expiresAt, now.add(const Duration(seconds: 60)));
      expect(result.mayPersist, isTrue);
      for (final invalid in [
        {'cache-control': 'max-age=120, max-age=360'},
        {'cache-control': 'max-age=120', 'age': 'bad'},
        {'cache-control': 'max-age=120', 'date': 'bad'},
        {'vary': 'accept-language'},
        {'expires': 'bad'},
      ]) {
        headers = invalid;
        expect(
          (await transport.fetch(key(), LoadCancellationSource())).mayPersist,
          isFalse,
        );
      }
    },
  );
  test(
    'offline dispatch never constructs a signed transport location',
    () async {
      var locations = 0;
      final transport = GeoByteSourceTransport(
        source: Source((_, _) async => throw StateError('no network')),
        locate: (_) {
          locations++;
          return GeoTransportLocation(
            uri: Uri.parse('https://example.test/tile?token=private'),
          );
        },
      );
      final store = MemoryGeoDataStore(maxBytes: 10, maxEntries: 1);
      final resolver = GeoResourceResolver(
        store: store,
        fetch: transport.fetch,
      );
      await expectLater(
        resolver.resolve(
          GeoResourceRequest(
            key: key(),
            policy: GeoReadPolicy(mode: GeoAccessMode.offlineOnly),
          ),
          cancellation: LoadCancellationSource(),
        ),
        error(GeoDataError.offlineMiss),
      );
      expect(locations, 0);
      await resolver.close();
      await store.close();
    },
  );
  test(
    'HTTP denial and missing content cannot fall back to stale bytes',
    () async {
      final store = MemoryGeoDataStore(maxBytes: 10, maxEntries: 1);
      await store.write(resource(key()));
      var status = 403;
      final transport = GeoByteSourceTransport(
        source: Source(
          (uri, _) async => throw AssetLoadException(
            AssetLoadError.sourceFailed,
            'private location',
            sourceUri: uri,
            httpStatus: status,
          ),
        ),
        locate: (_) => GeoTransportLocation(
          uri: Uri.parse('https://example.test/tile?token=private'),
        ),
      );
      final resolver = GeoResourceResolver(
        store: store,
        fetch: transport.fetch,
      );
      final policy = GeoReadPolicy(
        mode: GeoAccessMode.networkFirst,
        allowStaleOnTransportFailure: true,
      );
      for (final code in [401, 403, 407, 451, 404, 410]) {
        status = code;
        await expectLater(
          resolver.read(key(), policy, cancellation: LoadCancellationSource()),
          error(
            [401, 403, 407, 451].contains(code)
                ? GeoDataError.denied
                : GeoDataError.invalidResponse,
          ),
        );
      }
      status = 503;
      expect(
        (await resolver.read(
          key(),
          policy,
          cancellation: LoadCancellationSource(),
        )).bytes,
        [1, 2, 3],
      );
      await resolver.close();
      await store.close();
    },
  );
  test(
    'bounded reads enforce origin and do not persist restricted responses',
    () async {
      var headers = <String, String>{'cache-control': 'no-store'};
      var excessive = false, crossOrigin = false;
      final transport = GeoByteSourceTransport(
        maxBytes: 4,
        source: Source((uri, context) async {
          expect(context.maxBytes, 4);
          expect(context.headers['authorization'], 'Bearer private');
          context.reportProgress(excessive ? 5 : 3);
          return ResolvedSource(
            effectiveUri: crossOrigin ? Uri.parse('https://other.test') : uri,
            bytes: Uint8List.fromList([1, 2, 3]),
            headers: headers,
          );
        }),
        locate: (_) => GeoTransportLocation(
          uri: Uri.parse('https://example.test/tile?token=private'),
          headers: {'authorization': 'Bearer private'},
        ),
      );
      final store = MemoryGeoDataStore(maxBytes: 10, maxEntries: 1);
      final resolver = GeoResourceResolver(
        store: store,
        metadata: permission,
        fetch: transport.fetch,
        maxResourceBytes: 4,
      );
      final policy = GeoReadPolicy(mode: GeoAccessMode.networkFirst);
      for (final directive in [
        'no-store',
        'no-cache',
        'must-revalidate',
        'private',
      ]) {
        headers = {'cache-control': directive};
        expect(
          (await resolver.read(
            key(),
            policy,
            cancellation: LoadCancellationSource(),
          )).mayPersist,
          isFalse,
        );
        expect(store.entryCount, 0);
      }
      excessive = true;
      await expectLater(
        resolver.read(key(), policy, cancellation: LoadCancellationSource()),
        error(GeoDataError.budgetExceeded),
      );
      excessive = false;
      crossOrigin = true;
      await expectLater(
        resolver.read(key(), policy, cancellation: LoadCancellationSource()),
        error(GeoDataError.denied),
      );
      await resolver.close();
      await store.close();
    },
  );
}
