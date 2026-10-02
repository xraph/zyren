import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_engineering/http_session_store.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

void main() {
  test('CLI requires host credentials before creating a session', () async {
    final result = await Process.run(
      Platform.resolvedExecutable,
      [
        '--packages=${File('.dart_tool/package_config.json').absolute.path}',
        'packages/zyren_engineering/example/review_service.dart',
      ],
      environment: const {},
      includeParentEnvironment: false,
    );
    expect(result.exitCode, 64);
    expect(result.stdout, isEmpty);
    expect(result.stderr.toString(), contains('Set ZYREN_REVIEW_TOKEN'));
  });

  test(
    'CLI starts a persistent authenticated service and shuts down on SIGTERM',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'engineering-service-cli-',
      );
      final process = await Process.start(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          'packages/zyren_engineering/example/review_service.dart',
          '${temp.path}/session.json',
          'review',
        ],
        environment: const {'ZYREN_REVIEW_TOKEN': 'fixture-only-token'},
      );
      final errors = process.stderr.transform(utf8.decoder).join();
      final output = StreamIterator(
        process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
      );
      final client = HttpClient();
      try {
        expect(
          await output.moveNext().timeout(const Duration(seconds: 15)),
          isTrue,
        );
        final line = output.current;
        expect(line, startsWith('Review endpoint: '));
        expect(line, isNot(contains('fixture-only-token')));
        final endpoint = Uri.parse(line.substring('Review endpoint: '.length));
        final session = HttpEngineeringSessionStore(
          client: client,
          endpoint: endpoint,
          headers: () async => {'Authorization': 'Bearer fixture-only-token'},
        );
        final before = await session.read();
        final changed = EngineeringDocument(
          id: 'review',
          objects: [EngineeringObject(id: 'cad-key', label: 'Housing')],
        );
        final committed = await session.compareAndWrite(
          expectedVersion: before.version,
          document: changed,
        );
        expect((await session.read()).version, committed.version);
        expect(process.kill(ProcessSignal.sigterm), isTrue);
        expect(
          await process.exitCode.timeout(const Duration(seconds: 5)),
          0,
          reason: await errors,
        );
        expect(
          await File('${temp.path}/session.json').readAsString(),
          contains('cad-key'),
        );
      } finally {
        process.kill();
        client.close(force: true);
        await output.cancel();
        await process.exitCode;
        await temp.delete(recursive: true);
      }
    },
    skip: Platform.isWindows ? 'SIGTERM lifecycle test requires Unix.' : false,
  );
}
