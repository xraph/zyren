import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

GeoResourceKey key({
  String sourceVersion = '1',
  String partition = 'public',
  String? projection,
  String? time,
  int decoder = 1,
}) => GeoResourceKey(
  sourceId: 'sea',
  sourceVersion: sourceVersion,
  authorizationPartition: partition,
  address: 'mask/0/0/0',
  representation: 'r8',
  decoderVersion: decoder,
  projection: projection,
  timeSlice: time,
);
GeoResource resource(
  GeoResourceKey key, {
  DateTime? fetchedAt,
  List<int> bytes = const [1, 2, 3],
}) => GeoResource(
  key: key,
  bytes: Uint8List.fromList(bytes),
  fetchedAt: fetchedAt ?? DateTime.utc(2026),
  checksum: sha256.convert(bytes).toString(),
);
void main() {
  test(
    'typed key identity separates every source and authorization dimension',
    () {
      final keys = [
        key(),
        key(sourceVersion: '2'),
        key(partition: 'tenant-1'),
        key(projection: 'EPSG:4326'),
        key(time: '2026-01'),
        key(decoder: 2),
      ];
      expect(keys.map((k) => k.digest).toSet(), hasLength(keys.length));
      expect(GeoResourceKey.fromJson(key().toJson()), key());
      expect(key().digest, matches(RegExp(r'^[a-f0-9]{64}$')));
      for (final address in [
        'https://example.com/tiles?token=secret',
        '../escape',
        '/tmp/a',
        'tiles?key=x',
      ]) {
        expect(
          () => GeoResourceKey(
            sourceId: 'sea',
            sourceVersion: '1',
            authorizationPartition: 'public',
            address: address,
            representation: 'r8',
            decoderVersion: 1,
          ),
          throwsArgumentError,
        );
      }
    },
  );
  test(
    'resources own immutable bytes and verify checksums before storage',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      final value = GeoResource(
        key: key(),
        bytes: bytes,
        fetchedAt: DateTime.utc(2026),
        checksum: sha256.convert(bytes).toString(),
      );
      bytes[0] = 7;
      expect(value.bytes[0], 1);
      expect(() => value.bytes[0] = 2, throwsUnsupportedError);
      final store = MemoryGeoDataStore(maxBytes: 4, maxEntries: 1);
      expect(await store.write(value), isTrue);
      expect(
        await store.write(
          resource(key(sourceVersion: '2'), bytes: [5, 6, 7, 8, 9]),
        ),
        isFalse,
      );
      expect(await store.read(key()), isNotNull);
      final corrupt = GeoResource(
        key: key(),
        bytes: Uint8List.fromList([9]),
        fetchedAt: DateTime.utc(2026),
        checksum: value.checksum,
      );
      await expectLater(
        store.write(corrupt),
        throwsA(
          isA<GeoDataException>().having(
            (e) => e.code,
            'code',
            GeoDataError.corrupt,
          ),
        ),
      );
      await store.close();
    },
  );
}
