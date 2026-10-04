import 'dart:io';

import 'package:test/test.dart';
import 'package:zyren_ml/src/runtime.dart' show loadProviderModel;
import 'package:zyren_ml/src/session.dart' show loadValidatedSession;
import 'package:zyren_ml/zyren_ml.dart';

void main() {
  final model = MlModelManifest.decode(
    File('test/fixtures/linear.json').readAsStringSync(),
  );
  final bytes = File('test/fixtures/linear.onnx').readAsBytesSync();
  final input = {
    'observation': MlTensor.float32([1, 4], [1, 2, 3, 4]),
  };
  const runtime = MlRuntime();
  test('qualification expires while model assets are resolving', () async {
    final deadline = DateTime.now();
    await expectLater(
      loadProviderModel(model, (_) async {
        await Future<void>.delayed(const Duration(milliseconds: 2));
        return bytes;
      }, qualificationDeadline: deadline),
      throwsA(
        isA<MlLoadException>()
            .having((e) => e.status, 'status', MlRunStatus.unsupported)
            .having((e) => e.message, 'message', contains('asset preparation')),
      ),
    );
    expect(runtime.diagnostics.liveSessions, 0);
    expect(runtime.diagnostics.liveResults, 0);
  });
  test(
    'qualification revoked during preparation prevents native execution',
    () async {
      var checks = 0;
      final session = loadValidatedSession(
        model,
        bytes,
        inputQualification: (_) => ++checks == 1,
      );
      final before = runtime.diagnostics.completedRuns;
      try {
        final result = await session.run(input);
        expect(result.status, MlRunStatus.unsupported);
        expect(result.tensors, isEmpty);
        expect(runtime.diagnostics.completedRuns, before);
      } finally {
        await session.close();
      }
      expect(runtime.diagnostics.liveSessions, 0);
      expect(runtime.diagnostics.liveResults, 0);
    },
  );
  test(
    'qualification revoked after completion discards output and releases native storage',
    () async {
      var checks = 0;
      final session = loadValidatedSession(
        model,
        bytes,
        inputQualification: (_) => ++checks <= 2,
      );
      final before = runtime.diagnostics.completedRuns;
      try {
        final result = await session.run(input);
        expect(result.status, MlRunStatus.unsupported);
        expect(result.tensors, isEmpty);
        expect(runtime.diagnostics.completedRuns, before + 1);
      } finally {
        await session.close();
      }
      expect(runtime.diagnostics.liveSessions, 0);
      expect(runtime.diagnostics.liveResults, 0);
    },
  );
}
