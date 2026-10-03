import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'package:test/test.dart';
import 'package:zyren_geospatial/offline.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'identity_test.dart' show key, resource;
import 'resolver_test.dart' show error;

File projectFile(String path) {
  var directory = Directory.current;
  while (!File(
    '${directory.path}/packages/zyren_geospatial/pubspec.yaml',
  ).existsSync()) {
    if (directory.parent.path == directory.path) {
      throw StateError('Workspace unavailable.');
    }
    directory = directory.parent;
  }
  return File('${directory.path}/$path');
}

Future<Process> launch(
  String mode,
  Directory directory,
  String label, [
  String? stage,
]) => Process.start(Platform.resolvedExecutable, [
  '--packages=${projectFile('.dart_tool/package_config.json').path}',
  projectFile(
    'packages/zyren_geospatial/test/data/support/store_process.dart',
  ).path,
  mode,
  directory.path,
  label,
  ?stage,
]);
Future<bool> writeInIsolate(String path) => Isolate.run(() async {
  final other = FileGeoDataStore(
    directory: Directory(path),
    maxBytes: 1024 * 1024,
    maxEntries: 64,
  );
  final result = await other.write(resource(key(sourceVersion: 'isolate')));
  await other.close();
  return result;
});

void main() {
  late Directory directory;
  setUp(
    () async =>
        directory = await Directory.systemTemp.createTemp('zyren-geo-process-'),
  );
  tearDown(() async => directory.delete(recursive: true));
  test(
    'two processes preserve every committed entry under concurrent writes',
    () async {
      final first = await launch('write', directory, 'one');
      final second = await launch('write', directory, 'two');
      final errors = [
        first.stderr.transform(utf8.decoder).join(),
        second.stderr.transform(utf8.decoder).join(),
      ];
      expect(await first.exitCode, 0, reason: await errors[0]);
      expect(await second.exitCode, 0, reason: await errors[1]);
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 1024 * 1024,
        maxEntries: 64,
      );
      expect((await store.inspect()).entries, 16);
      for (final label in ['one', 'two']) {
        for (var i = 0; i < 8; i++) {
          expect((await store.read(key(sourceVersion: '$label-$i')))!.bytes, [
            1,
            2,
            3,
          ]);
        }
      }
      await store.close();
    },
  );
  test(
    'held process lock times out without releasing the writer lock',
    () async {
      final child = await launch('hold', directory, 'held');
      final errors = child.stderr.transform(utf8.decoder).join();
      try {
        expect(
          await child.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 20)),
          'ready',
        );
        final store = FileGeoDataStore(
          directory: directory,
          maxBytes: 1024 * 1024,
          maxEntries: 64,
          lockTimeout: const Duration(milliseconds: 50),
        );
        await expectLater(
          store.inspect(),
          error(GeoDataError.transportFailure),
        );
        child.stdin.writeln('release');
        expect(await child.exitCode, 0, reason: await errors);
        expect((await store.read(key(sourceVersion: 'held-0')))!.bytes, [
          1,
          2,
          3,
        ]);
        await store.close();
      } finally {
        child.kill();
      }
    },
  );
  test(
    'process termination at each journal stage recovers only committed data',
    () async {
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 1024 * 1024,
        maxEntries: 64,
      );
      await store.write(resource(key()));
      await store.pin('saved-region', {key().digest});
      for (final stage in GeoStoreWriteStage.values) {
        final child = await launch('crash', directory, stage.name, stage.name);
        final errors = child.stderr.transform(utf8.decoder).join();
        expect(await child.exitCode, 71, reason: await errors);
        final value = await store.read(key(sourceVersion: '${stage.name}-0'));
        expect(
          value,
          stage == GeoStoreWriteStage.indexCommitted ? isNotNull : isNull,
        );
        expect((await store.read(key()))!.bytes, [1, 2, 3]);
        expect((await store.inspect()).temporaryBytes, 0);
      }
      await store.close();
    },
  );
  test(
    'isolate gate prevents POSIX process locks from permitting lost updates',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      final store = FileGeoDataStore(
        directory: directory,
        maxBytes: 1024 * 1024,
        maxEntries: 64,
        onWriteStage: (stage) async {
          if (stage == GeoStoreWriteStage.payloadStaged) {
            entered.complete();
            await release.future;
          }
        },
      );
      final first = store.write(resource(key()));
      await entered.future;
      final path = directory.path;
      var secondFinished = false;
      final second = writeInIsolate(path).then((value) {
        secondFinished = true;
        return value;
      });
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(secondFinished, isFalse);
      release.complete();
      expect(await first, isTrue);
      expect(await second, isTrue);
      expect((await store.inspect()).entries, 2);
      await store.close();
    },
  );
}
