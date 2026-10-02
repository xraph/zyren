import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_engineering/file_session_store.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

EngineeringDocument doc([String label = 'Housing']) => EngineeringDocument(
  id: 'review',
  objects: [EngineeringObject(id: 'a', label: label)],
);

void main() {
  late Directory temp;
  late File file;
  late FileEngineeringSessionStore store;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('engineering-session-test-');
    file = File('${temp.path}/session.json');
    store = FileEngineeringSessionStore(file: file, documentId: 'review');
  });
  tearDown(() async => temp.delete(recursive: true));

  test(
    'initialization and restart retain document and persistent revision',
    () async {
      final first = await store.initialize(doc());
      final reopened = FileEngineeringSessionStore(
        file: file,
        documentId: 'review',
      );
      expect(
        (await reopened.initialize(doc('Discarded'))).version,
        first.version,
      );
      expect((await reopened.read()).document.objects['a']!.label, 'Housing');
      final changed = await reopened.compareAndWrite(
        expectedVersion: first.version,
        document: doc('Cover'),
      );
      expect(changed.version, isNot(first.version));
      expect((await store.read()).version, changed.version);
      await expectLater(
        store.compareAndWrite(
          expectedVersion: first.version,
          document: doc('Stale'),
        ),
        throwsA(isA<EngineeringVersionConflict>()),
      );
      expect((await store.read()).document.objects['a']!.label, 'Cover');
      expect(temp.listSync().whereType<Directory>(), isEmpty);
    },
  );

  test(
    'two instances serialize conditional writes in the same isolate',
    () async {
      final first = await store.initialize(doc());
      final other = FileEngineeringSessionStore(
        file: file,
        documentId: 'review',
      );
      Future<bool> write(
        FileEngineeringSessionStore writer,
        String label,
      ) async {
        try {
          await writer.compareAndWrite(
            expectedVersion: first.version,
            document: doc(label),
          );
          return true;
        } on EngineeringVersionConflict {
          return false;
        }
      }

      final results = await Future.wait([
        write(store, 'Left'),
        write(other, 'Right'),
      ]);
      expect(results.where((result) => result), hasLength(1));
      expect(
        (await store.read()).document.objects['a']!.label,
        anyOf('Left', 'Right'),
      );
    },
  );

  test('separate processes cannot both accept the same base version', () async {
    final first = await store.initialize(doc());
    Future<ProcessResult> writer(String label) =>
        Process.run(Platform.resolvedExecutable, [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          File(
            'packages/zyren_engineering/test/fixtures/session_writer.dart',
          ).absolute.path,
          file.path,
          first.version,
          label,
        ]);
    final results = await Future.wait([
      writer('Left process'),
      writer('Right process'),
    ]);
    for (final result in results) {
      expect(result.exitCode, 0, reason: result.stderr.toString());
    }
    expect(
      results.map((result) => result.stdout.toString().trim()),
      unorderedEquals(['written', 'conflict']),
    );
    expect(
      (await store.read()).document.objects['a']!.label,
      anyOf('Left process', 'Right process'),
    );
  });

  test(
    'corruption and wrong document ownership fail without replacement',
    () async {
      final first = await store.initialize(doc());
      expect(
        () => store.compareAndWrite(
          expectedVersion: first.version,
          document: EngineeringDocument(id: 'other'),
        ),
        throwsFormatException,
      );
      final other = FileEngineeringSessionStore(
        file: file,
        documentId: 'other',
      );
      await expectLater(other.read(), throwsFormatException);
      await file.writeAsString('{broken');
      await expectLater(
        store.initialize(doc('Overwrite')),
        throwsFormatException,
      );
      expect(await file.readAsString(), '{broken');
    },
  );
}
