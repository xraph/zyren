import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';

Future<Uint8List> resolveFixture(String path) =>
    File('test/fixtures/$path').readAsBytes();
MlModelManifest manifest(String name) =>
    MlModelManifest.decode(File('test/fixtures/$name.json').readAsStringSync());
Map<String, dynamic> fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.values.json').readAsStringSync())
        as Map<String, dynamic>;
MlTensorMap inputs(String name) =>
    (fixture(name)['inputs'] as Map<String, dynamic>).map(
      (key, value) => MapEntry(
        key,
        MlTensor.float32(
          (value['shape'] as List).cast<int>(),
          (value['values'] as List).cast<num>(),
        ),
      ),
    );
Matcher loadStatus(MlRunStatus status) =>
    isA<MlLoadException>().having((e) => e.status, 'status', status);
List<int> field(int number, List<int> data) {
  List<int> varint(int n) {
    final out = <int>[];
    while (n > 127) {
      out.add((n & 127) | 128);
      n >>= 7;
    }
    return out..add(n);
  }

  return [...varint(number * 8 + 2), ...varint(data.length), ...data];
}

void main() {
  const runtime = MlRuntime();
  test(
    'deadline expiring during valid input preparation skips native execution',
    () async {
      final session = await runtime.load(manifest('cnn_step'), resolveFixture);
      try {
        final image = MlTensor(MlDtype.float32, [
          64,
          3,
          84,
          84,
        ], Uint8List(64 * 3 * 84 * 84 * 4));
        expect((await session.run(inputs('cnn_step'))).status, MlRunStatus.ok);
        final before = runtime.diagnostics.completedRuns;
        final result = await session.run(
          {'image': image},
          MlRunOptions(
            deadline: DateTime.now().add(const Duration(milliseconds: 10)),
          ),
        );
        expect(result.status, MlRunStatus.cancelled);
        expect(result.message, 'Request expired during input preparation.');
        expect(runtime.diagnostics.completedRuns, before);
      } finally {
        await session.close();
      }
    },
  );
  for (final name in ['linear', 'lstm_step', 'cnn_step']) {
    test('native $name fixture parity and repeated close', () async {
      final expected = fixture(name)['outputs'] as Map<String, dynamic>;
      for (var iteration = 0; iteration < 10; iteration++) {
        final session = await runtime.load(manifest(name), resolveFixture);
        try {
          final output = await session.run(
            inputs(name),
            MlRunOptions(requestId: '$name-$iteration'),
          );
          expect(output.status, MlRunStatus.ok, reason: output.message);
          expect(output.requestId, '$name-$iteration');
          for (final entry in expected.entries) {
            final tensor = output.tensors[entry.key]!;
            expect(tensor.shape, entry.value['shape']);
            expect(tensor.float32Values.every((v) => v.isFinite), isTrue);
            final values = (entry.value['values'] as List).cast<num>();
            for (var i = 0; i < values.length; i++) {
              expect(tensor.float32Values[i], closeTo(values[i], 1e-5));
            }
          }
          expect(runtime.diagnostics.liveResults, 0);
        } finally {
          await session.close();
          await session.close();
        }
        expect(runtime.diagnostics.liveSessions, 0);
        expect(runtime.diagnostics.liveResults, 0);
      }
    });
  }

  test(
    '1000 recurrent native steps preserve explicit hidden/cell state',
    () async {
      final session = await runtime.load(manifest('lstm_step'), resolveFixture);
      try {
        var state = inputs('lstm_step');
        final sequence =
            jsonDecode(
                  File(
                    'test/fixtures/lstm_sequence.values.json',
                  ).readAsStringSync(),
                )
                as List;
        expect(sequence.length, 1000);
        for (final step in sequence.cast<Map<String, dynamic>>()) {
          if (step['reset'] == true) state = inputs('lstm_step');
          state['observation'] = MlTensor.float32([
            1,
            4,
          ], (step['observation'] as List).cast<num>());
          final result = await session.run(state);
          expect(result.status, MlRunStatus.ok, reason: result.message);
          final expected = step['outputs'] as Map<String, dynamic>;
          for (final entry in expected.entries) {
            final values = result.tensors[entry.key]!.float32Values;
            final reference = (entry.value as List).cast<num>();
            for (var i = 0; i < values.length; i++) {
              expect(values[i], closeTo(reference[i], 1e-5));
            }
          }
          state = {
            'observation': state['observation']!,
            'hidden': result.tensors['next_hidden']!,
            'cell': result.tensors['next_cell']!,
          };
        }
        expect(runtime.diagnostics.liveResults, 0);
      } finally {
        await session.close();
      }
      expect(runtime.diagnostics.liveSessions, 0);
    },
  );

  test(
    'native int64/bool preserve values and independent actor batch slots',
    () async {
      final session = await runtime.load(
        manifest('typed_identity'),
        resolveFixture,
      );
      try {
        final result = await session.run({
          'ids': MlTensor.int64([2, 2], [-7, 1 << 40, 3, 42]),
          'mask': MlTensor(MlDtype.bool, [
            2,
            2,
          ], Uint8List.fromList([1, 0, 0, 1])),
        });
        expect(result.status, MlRunStatus.ok, reason: result.message);
        expect(result.tensors['next_ids']!.int64Values, [-7, 1 << 40, 3, 42]);
        expect(result.tensors['next_mask']!.boolValues, [
          true,
          false,
          false,
          true,
        ]);
        expect(result.tensors['next_ids']!.shape, [2, 2]);
      } finally {
        await session.close();
      }
      expect(runtime.diagnostics.liveSessions, 0);
      expect(runtime.diagnostics.liveResults, 0);
    },
  );

  test(
    'invalid inputs, cancelled/deadline and closed session are typed',
    () async {
      final session = await runtime.load(manifest('lstm_step'), resolveFixture);
      try {
        expect(
          (await session.run(inputs('lstm_step')..remove('hidden'))).status,
          MlRunStatus.invalid,
        );
        expect(
          (await session.run(
            inputs('lstm_step')..['extra'] = MlTensor.float32([1], [1]),
          )).status,
          MlRunStatus.invalid,
        );
        expect(
          (await session.run(
            inputs('lstm_step')
              ..['observation'] = MlTensor.float32(
                [1, 4],
                [double.nan, 0, 0, 0],
              ),
          )).status,
          MlRunStatus.invalid,
        );
        expect(
          (await session.run(
            inputs('lstm_step')
              ..['hidden'] = MlTensor.float32([2, 8], List.filled(16, 0)),
          )).status,
          MlRunStatus.invalid,
        );
        final token = MlCancellationToken()..cancel();
        expect(
          (await session.run(
            inputs('lstm_step'),
            MlRunOptions(cancellation: token),
          )).status,
          MlRunStatus.cancelled,
        );
        expect(
          (await session.run(
            inputs('lstm_step'),
            MlRunOptions(
              deadline: DateTime.now().subtract(const Duration(seconds: 1)),
            ),
          )).status,
          MlRunStatus.cancelled,
        );
      } finally {
        await session.close();
      }
      expect(
        (await session.run(inputs('lstm_step'))).status,
        MlRunStatus.unavailable,
      );
    },
  );

  test(
    'hash, opset and custom library validation precede native loading',
    () async {
      expect(
        runtime.load(
          manifest('linear'),
          (_) async => Uint8List.fromList([1, 2, 3]),
        ),
        throwsA(loadStatus(MlRunStatus.invalid)),
      );
      final wrongSpec =
          jsonDecode(manifest('linear').encode()) as Map<String, dynamic>;
      (wrongSpec['inputs'] as List).first['name'] = 'different_input';
      await expectLater(
        runtime.load(
          MlModelManifest.decode(jsonEncode(wrongSpec)),
          resolveFixture,
        ),
        throwsA(loadStatus(MlRunStatus.invalid)),
      );
      final json =
          jsonDecode(manifest('linear').encode()) as Map<String, dynamic>;
      expect(
        runtime.load(
          MlModelManifest.decode(jsonEncode({...json, 'opset': 999})),
          resolveFixture,
        ),
        throwsA(loadStatus(MlRunStatus.unsupported)),
      );
      expect(
        runtime.load(
          MlModelManifest.decode(
            jsonEncode({
              ...json,
              'customOperatorLibraries': ['custom.dylib'],
            }),
          ),
          resolveFixture,
        ),
        throwsA(loadStatus(MlRunStatus.unsupported)),
      );
      expect(
        runtime.load(
          manifest('linear'),
          (_) async => throw FileSystemException('missing'),
        ),
        throwsA(loadStatus(MlRunStatus.unavailable)),
      );
    },
  );

  test(
    'actual model custom domains and external traversal are rejected',
    () async {
      final source = await resolveFixture('linear.onnx');
      final json =
          jsonDecode(manifest('linear').encode()) as Map<String, dynamic>;
      Future<void> rejects(List<int> extra, MlRunStatus status) async {
        final bytes = Uint8List.fromList([...source, ...extra]);
        final model = MlModelManifest.decode(
          jsonEncode({...json, 'sha256': sha256.convert(bytes).toString()}),
        );
        await expectLater(
          runtime.load(model, (_) async => bytes),
          throwsA(loadStatus(status)),
        );
      }

      // An extra custom opset cannot be hidden behind a standard manifest pin.
      await rejects(
        field(8, [...field(1, utf8.encode('evil.custom')), 16, 17]),
        MlRunStatus.unsupported,
      );
      // Append a second graph containing an initializer with an external location.
      final entry = [
        ...field(1, utf8.encode('location')),
        ...field(2, utf8.encode('../outside.bin')),
      ];
      await rejects(field(7, field(5, field(13, entry))), MlRunStatus.invalid);
      final safe = [
        ...field(1, utf8.encode('location')),
        ...field(2, utf8.encode('weights.bin')),
      ];
      await rejects(
        field(7, field(5, field(13, safe))),
        MlRunStatus.unsupported,
      );
      expect(runtime.diagnostics.liveSessions, 0);
    },
  );
}
