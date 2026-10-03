import 'dart:io';
import 'dart:async';
import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:test/test.dart';
import 'package:zyren_geospatial/offline.dart';
import 'identity_test.dart' show key, resource;
import 'resolver_test.dart' show error;

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('zyren-geo-store-'),
  );
  tearDown(() async => directory.delete(recursive: true));
  test(
    'resource survives a cold store restart with metadata and checksum',
    () async {
      final first = FileGeoDataStore(
        directory: directory,
        maxBytes: 16384,
        maxEntries: 8,
      );
      final value = resource(key());
      expect(await first.write(value), isTrue);
      await first.close();
      final restarted = FileGeoDataStore(
        directory: directory,
        maxBytes: 16384,
        maxEntries: 8,
      );
      final result = await restarted.read(key());
      expect(result!.bytes, [1, 2, 3]);
      expect(result.fetchedAt, value.fetchedAt);
      expect(result.checksum, value.checksum);
      final stats = await restarted.inspect();
      expect(stats.committedBytes, 3);
      expect(stats.temporaryBytes, 0);
      expect(stats.metadataBytes, greaterThan(0));
      expect(stats.totalBytes, lessThanOrEqualTo(16384));
      await restarted.close();
    },
  );
  test(
    'independent manifest pins survive pressure and unpinning another owner',
    () async {
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 16384,
        maxEntries: 1,
      );
      await store.write(resource(key()));
      await store.pin('region-a', {key().digest});
      await store.pin('region-b', {key().digest});
      expect((await store.inspect()).pinnedBytes, 3);
      expect(await store.write(resource(key(sourceVersion: '2'))), isFalse);
      await store.unpin('region-a');
      expect(await store.write(resource(key(sourceVersion: '2'))), isFalse);
      await store.unpin('region-b');
      expect(await store.write(resource(key(sourceVersion: '2'))), isTrue);
      expect(await store.read(key()), isNull);
      await store.close();
    },
  );
  test(
    'each interrupted publication preserves the previous pinned resource',
    () async {
      var fail = false;
      GeoStoreWriteStage? stage;
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 16384,
        maxEntries: 8,
        onWriteStage: (value) {
          if (fail && value == stage) throw StateError('injected disk failure');
        },
      );
      await store.write(resource(key()));
      await store.pin('saved-region', {key().digest});
      for (final point in GeoStoreWriteStage.values) {
        stage = point;
        fail = true;
        final candidate = key(sourceVersion: point.name);
        await expectLater(
          store.write(resource(candidate)),
          error(GeoDataError.transportFailure),
        );
        fail = false;
        expect((await store.read(key()))!.bytes, [1, 2, 3]);
        expect(
          await store.read(candidate),
          point == GeoStoreWriteStage.indexCommitted ? isNotNull : isNull,
        );
        final stats = await store.inspect();
        expect(stats.temporaryBytes, 0);
        expect(stats.pinnedBytes, 3);
        expect(stats.totalBytes, lessThanOrEqualTo(16384));
      }
      await store.close();
    },
  );
  test(
    'pin replacement is atomic and unknown resources do not replace existing pins',
    () async {
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 16384,
        maxEntries: 1,
      );
      await store.write(resource(key()));
      await store.pin('region', {key().digest});
      await expectLater(
        store.pin('region', {key(sourceVersion: 'missing').digest}),
        error(GeoDataError.offlineMiss),
      );
      expect((await store.inspect()).pinnedBytes, 3);
      expect(
        await store.write(resource(key(sourceVersion: 'replacement'))),
        isFalse,
      );
      await expectLater(store.remove(key()), error(GeoDataError.denied));
      expect(() => store.pin('../escape', {key().digest}), throwsArgumentError);
      await store.close();
    },
  );
  test(
    'payload and index corruption fail explicitly without trusting orphan data',
    () async {
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 16384,
        maxEntries: 8,
      );
      await store.write(resource(key()));
      final blob = directory.listSync().whereType<File>().singleWhere(
        (f) => f.path.endsWith('.blob'),
      );
      await blob.writeAsBytes([9, 8, 7]);
      await expectLater(store.read(key()), error(GeoDataError.corrupt));
      await store.remove(key());
      await store.write(resource(key()));
      final index = File('${directory.path}/index.json');
      final envelope = jsonDecode(await index.readAsString()) as Map;
      envelope['body'] = '{}';
      await index.writeAsString(jsonEncode(envelope));
      await expectLater(store.inspect(), error(GeoDataError.corrupt));
      expect(blob.existsSync(), isTrue);
      await store.close();
    },
  );
  test(
    'symlink roots, blobs and metadata cannot escape the owned directory',
    () async {
      if (Platform.isWindows) return;
      final outside = await Directory.systemTemp.createTemp(
        'zyren-geo-outside-',
      );
      try {
        final original = File('${outside.path}/original');
        await original.writeAsString('keep');
        final rootLink = Link('${directory.path}/linked');
        await rootLink.create(outside.path);
        final linked = FileGeoDataStore(
          directory: Directory(rootLink.path),
          maxBytes: 16384,
          maxEntries: 8,
        );
        await expectLater(linked.inspect(), error(GeoDataError.denied));
        await linked.close();
        await rootLink.delete();
        final store = FileGeoDataStore(
          directory: directory,
          maxBytes: 16384,
          maxEntries: 8,
        );
        await store.write(resource(key()));
        final blob = directory.listSync().whereType<File>().singleWhere(
          (f) => f.path.endsWith('.blob'),
        );
        await blob.delete();
        await Link(blob.path).create(original.path);
        await expectLater(store.read(key()), error(GeoDataError.denied));
        expect(await original.readAsString(), 'keep');
        await store.close();
      } finally {
        await outside.delete(recursive: true);
      }
    },
  );
  test(
    'cancellation recovers staging and close drains accepted operations',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final cancellation = LoadCancellationSource();
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 16384,
        maxEntries: 8,
        onWriteStage: (stage) async {
          if (stage == GeoStoreWriteStage.payloadStaged) {
            entered.complete();
            await release.future;
          }
        },
      );
      final write = store.write(resource(key()), cancellation: cancellation);
      final failure = expectLater(write, error(GeoDataError.cancelled));
      await entered.future;
      var closed = false;
      final close = store.close().then((_) => closed = true);
      cancellation.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      release.complete();
      await failure;
      await close;
      final restarted = FileGeoDataStore(
        directory: directory,
        maxBytes: 16384,
        maxEntries: 8,
      );
      expect(await restarted.read(key()), isNull);
      expect((await restarted.inspect()).temporaryBytes, 0);
      await expectLater(store.read(key()), error(GeoDataError.closed));
      await restarted.close();
    },
  );
  test(
    'admission reserves journal bytes and cannot evict pinned data',
    () async {
      var peak = 0;
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 12000,
        maxEntries: 8,
        onWriteStage: (_) async {
          var total = 0;
          await for (final file in directory.list()) {
            if (file is File) total += await file.length();
          }
          if (total > peak) peak = total;
        },
      );
      expect(
        await store.write(resource(key(), bytes: List.filled(6000, 1))),
        isTrue,
      );
      expect(
        await store.write(
          resource(key(sourceVersion: '2'), bytes: List.filled(6000, 2)),
        ),
        isTrue,
      );
      expect(await store.read(key()), isNull);
      await store.pin('large-region', {key(sourceVersion: '2').digest});
      expect(
        await store.write(
          resource(key(sourceVersion: '3'), bytes: List.filled(6000, 3)),
        ),
        isFalse,
      );
      expect(peak, lessThanOrEqualTo(12000));
      expect((await store.inspect()).pinnedBytes, 6000);
      await store.close();
    },
  );
}
