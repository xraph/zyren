import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'native_inference_test.dart' as fixture;

void main() {
  const runtime = MlRuntime();
  final receipts = <String, Object?>{};
  Map<String, int> counters() => {
    'nativeSessions': runtime.diagnostics.liveSessions,
    'nativeResults': runtime.diagnostics.liveResults,
    'nativeRuns': runtime.diagnostics.activeRuns,
  };
  tearDownAll(() async {
    final path = Platform.environment['GAME_FAILURE_RECEIPT_PATH'];
    if (path == null) return;
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      const JsonEncoder.withIndent(
        '  ',
      ).convert({'schemaVersion': 1, 'cases': receipts}),
    );
  });
  for (final id in ['model.hash', 'model.schema', 'model.operator']) {
    test('$id preserves live native inference and recovers', () async {
      final baseline = counters();
      final valid = fixture.manifest('linear');
      final session = await runtime.load(valid, fixture.resolveFixture);
      Future<Map<String, Object?>> identity() async {
        final output = await session.run(fixture.inputs('linear'));
        expect(output.status, MlRunStatus.ok);
        return {
          'modelHash': session.manifest.sha256,
          'manifest': session.manifest.encode(),
          'closed': session.isClosed,
          'outputHash': sha256
              .convert(output.tensors['action']!.bytes)
              .toString(),
          'owners': counters(),
        };
      }

      late Map<String, Object?> before, after;
      late MlRunStatus status;
      try {
        before = await identity();
        var bytes = await fixture.resolveFixture('linear.onnx');
        final manifest = jsonDecode(valid.encode()) as Map<String, dynamic>;
        switch (id) {
          case 'model.hash':
            bytes = Uint8List.fromList(bytes)..[bytes.length - 1] ^= 1;
            status = MlRunStatus.invalid;
          case 'model.schema':
            (manifest['inputs'] as List).first['name'] = 'different_input';
            status = MlRunStatus.invalid;
          case 'model.operator':
            // Keep protobuf lengths intact and ask actual ORT to load an
            // unregistered standard-domain operator with a correctly pinned SHA.
            final source = latin1.decode(bytes);
            final index =
                source.indexOf(
                  '${String.fromCharCode(34)}${String.fromCharCode(4)}Gemm',
                ) +
                2;
            expect(index, greaterThanOrEqualTo(2));
            bytes = Uint8List.fromList(bytes)
              ..setRange(index, index + 4, ascii.encode('NoOp'));
            manifest['sha256'] = sha256.convert(bytes).toString();
            status = MlRunStatus.failed;
        }
        await expectLater(
          runtime
              .load(
                MlModelManifest.decode(jsonEncode(manifest)),
                (_) async => bytes,
              )
              .then((unexpected) async {
                await unexpected.close();
                fail('Invalid model was admitted.');
              }),
          throwsA(fixture.loadStatus(status)),
        );
        after = await identity();
        expect(after, before);
        final retry = await runtime.load(valid, fixture.resolveFixture);
        try {
          expect(
            (await retry.run(fixture.inputs('linear'))).status,
            MlRunStatus.ok,
          );
        } finally {
          await retry.close();
        }
      } finally {
        await session.close();
      }
      expect(counters(), baseline);
      receipts[id] = {
        'status': 'passed',
        'actualStatus': 'rejected',
        'nativeStatus': status.name,
        'before': before,
        'after': after,
        'cleanupCounters': {'before': baseline, 'after': counters()},
        'recovery': {'action': 'retry_valid_model', 'status': 'passed'},
        'execution': {
          'kind': 'native',
          'provider': 'native-onnxruntime-1.23.2-cpu',
          'os': Platform.operatingSystem,
          'exitCode': 0,
          'command':
              'fvm dart test --concurrency=1 test/failure_receipts_test.dart',
        },
      };
    });
  }
}
