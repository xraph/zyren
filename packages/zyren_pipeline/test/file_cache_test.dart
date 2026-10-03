import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_pipeline/io.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import '../example/triangle_source.dart';

Future<PipelineBundle> makeBundle(double width) {
  final source = TriangleSource(width: width);
  return PipelineBuilder(
    resolver: source,
  ).build(entrySourceId: 'model', sources: source.sources);
}

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'zyren-pipeline-disk-test-',
    );
  });
  tearDown(() async {
    await directory.delete(recursive: true);
  });

  test(
    'reload, persistent pins, eviction and invalidation across cache handles',
    () async {
      final a = await makeBundle(1),
          b = await makeBundle(2),
          c = await makeBundle(3);
      final events = <String>[];
      final cache = FilePipelineCache(
        directory: directory,
        maxBundles: 2,
        onEvent: (event, _) => events.add(event),
      );
      expect(await cache.put(a, pin: true), isTrue);
      await cache.put(b);
      final restarted = FilePipelineCache(directory: directory, maxBundles: 2);
      expect((await restarted.get(a.version))!.version, a.version);
      expect(
        (await restarted.inspect()).where((e) => e.pinned).single.version,
        a.version,
      );
      await cache.put(c);
      expect(await cache.get(b.version), isNull);
      expect(await cache.get(a.version), isNotNull);
      expect(events, contains('evicted'));
      expect(await restarted.invalidateSource('positions'), hasLength(2));
      expect(await restarted.inspect(), isEmpty);
    },
  );

  test(
    'pinned or oversized admission cannot evict existing archives',
    () async {
      final a = await makeBundle(1), b = await makeBundle(10000);
      final cache = FilePipelineCache(
        directory: directory,
        maxBytes: a.encode().length,
        maxBundles: 1,
      );
      await cache.put(a, pin: true);
      expect(await cache.put(b), isFalse);
      expect((await cache.inspect()).single.version, a.version);
      final c = await makeBundle(2);
      expect(await cache.put(c), isFalse);
      await cache.setPinned(a.version, false);
      expect(await cache.put(c), isTrue);
      expect(await cache.get(a.version), isNull);
    },
  );

  test(
    'corruption is reported and abandoned temporary writes are recovered',
    () async {
      final a = await makeBundle(1);
      final events = <String>[];
      final cache = FilePipelineCache(
        directory: directory,
        onEvent: (event, _) => events.add(event),
      );
      await cache.put(a);
      await File(
        '${directory.path}/${a.version}.zybundle',
      ).writeAsString('broken');
      await File(
        '${directory.path}/.pipeline-99.tmp',
      ).writeAsString('interrupted');
      await expectLater(
        cache.get(a.version),
        throwsA(isA<PipelineCacheCorruption>()),
      );
      expect(events, containsAll(['recovered-temporary', 'corrupt']));
      expect(await cache.get(a.version), isNull);
      expect(
        await File('${directory.path}/.pipeline-99.tmp').exists(),
        isFalse,
      );
    },
  );

  test(
    'cancelled admission and symlink archives fail without following paths',
    () async {
      final a = await makeBundle(1);
      final cache = FilePipelineCache(directory: directory);
      final token = PipelineCancellation()..cancel();
      await expectLater(cache.put(a, cancellation: token), throwsA(anything));
      expect(await cache.inspect(), isEmpty);
      final external = await File(
        '${directory.path}/external',
      ).writeAsString('private');
      await Link(
        '${directory.path}/${a.version}.zybundle',
      ).create(external.path);
      await expectLater(
        cache.get(a.version),
        throwsA(isA<FileSystemException>()),
      );
      expect(await external.readAsString(), 'private');
    },
  );

  test('pins can be removed after reducing the budget', () async {
    final a = await makeBundle(1);
    await FilePipelineCache(directory: directory).put(a, pin: true);
    final smaller = FilePipelineCache(directory: directory, maxBytes: 1);
    await expectLater(smaller.inspect(), throwsStateError);
    expect(await smaller.setPinned(a.version, false), isTrue);
    expect(await smaller.inspect(), isEmpty);
  });

  test(
    'independent processes serialize writes and enforce one shared budget',
    () async {
      final a = await makeBundle(1), b = await makeBundle(2);
      final inputA = await File(
        '${directory.path}/a.input',
      ).writeAsBytes(a.encode());
      final inputB = await File(
        '${directory.path}/b.input',
      ).writeAsBytes(b.encode());
      final results = await Future.wait([
        for (final input in [inputA, inputB])
          Process.run(Platform.resolvedExecutable, [
            'run',
            'packages/zyren_pipeline/test/support/cache_writer.dart',
            directory.path,
            input.path,
          ]),
      ]);
      for (final result in results) {
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }
      final entries = await FilePipelineCache(
        directory: directory,
        maxBundles: 1,
      ).inspect();
      expect(entries, hasLength(1));
      expect({a.version, b.version}, contains(entries.single.version));
    },
  );
}
