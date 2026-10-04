import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';

MlModelManifest _manifest(String name) =>
    MlModelManifest.decode(File('test/fixtures/$name.json').readAsStringSync());
Map<String, dynamic> _fixture(String name) =>
    jsonDecode(File('test/fixtures/$name.values.json').readAsStringSync())
        as Map<String, dynamic>;
MlTensorMap _tensors(Map<String, dynamic> source) => source.map(
  (key, value) => MapEntry(
    key,
    MlTensor.float32(
      (value['shape'] as List).cast<int>(),
      (value['values'] as List).cast<num>(),
    ),
  ),
);
Iterable<MlProviderProbeStep> _sequence() sync* {
  final zero = _tensors(
    _fixture('lstm_step')['inputs'] as Map<String, dynamic>,
  );
  final rows =
      jsonDecode(
            File('test/fixtures/lstm_sequence.values.json').readAsStringSync(),
          )
          as List;
  for (final row in rows.cast<Map<String, dynamic>>()) {
    yield MlProviderProbeStep(
      inputs: {
        ...zero,
        'observation': MlTensor.float32([
          1,
          4,
        ], (row['observation'] as List).cast<num>()),
      },
      resetState: row['reset'] == true,
      referenceOutputs: (row['outputs'] as Map<String, dynamic>).map(
        (key, value) => MapEntry(
          key,
          MlTensor.float32([1, (value as List).length], value.cast<num>()),
        ),
      ),
    );
  }
}

void main() {
  const runtime = MlRuntime();
  const probe = MlProviderProbe();
  final receipts = <String, Object?>{};
  tearDown(() {
    expect(runtime.diagnostics.liveSessions, 0);
    expect(runtime.diagnostics.liveResults, 0);
    expect(runtime.diagnostics.activeRuns, 0);
  });
  tearDownAll(() {
    File(
      '/tmp/zyren-coreml-provider-probe.json',
    ).writeAsStringSync(jsonEncode(receipts));
  });
  test('inventory and default CPU session stay explicit', () async {
    expect(runtime.availableProviders, contains('CPUExecutionProvider'));
    final model = _manifest('linear');
    final session = await runtime.load(
      model,
      (path) => File('test/fixtures/$path').readAsBytes(),
    );
    try {
      expect(session.actualProvider, 'cpu');
      expect(
        (await session.run(
          _tensors(_fixture('linear')['inputs'] as Map<String, dynamic>),
        )).status,
        MlRunStatus.ok,
      );
    } finally {
      await session.close();
    }
  });
  test(
    'no-reference, unknown provider and invalid tolerance cannot mint a token',
    () async {
      var resolved = false;
      for (final provider in ['coreml', 'webgpu', 'unknown']) {
        final report = await probe.probe(
          model: _manifest('linear'),
          inputs: const {},
          provider: provider,
          resolver: (_) async {
            resolved = true;
            return File('test/fixtures/linear.onnx').readAsBytes();
          },
        );
        expect(report.status, MlRunStatus.unsupported);
        expect(report.actualProvider, isNull);
        expect(report.selection, isNull);
      }
      expect(resolved, isFalse);
      await expectLater(
        probe.probe(
          model: _manifest('linear'),
          inputs: const {},
          tolerance: double.nan,
          resolver: (_) async =>
              File('test/fixtures/linear.onnx').readAsBytes(),
        ),
        throwsArgumentError,
      );
      await expectLater(
        probe.probe(
          model: _manifest('linear'),
          inputs: const {},
          provider: 'coreml',
          warmSamples: 2,
          referenceOutputs: const {},
          resolver: (_) async =>
              File('test/fixtures/linear.onnx').readAsBytes(),
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'oversized provider asset is rejected before opening a native session',
    () async {
      final model = MlModelManifest.decode(
        jsonEncode({
          ...jsonDecode(_manifest('linear').encode()) as Map<String, dynamic>,
          'maxModelBytes': 1,
        }),
      );
      final report = await probe.probe(
        model: model,
        resolver: (_) => File('test/fixtures/linear.onnx').readAsBytes(),
        inputs: _tensors(_fixture('linear')['inputs'] as Map<String, dynamic>),
        referenceOutputs: _tensors(
          _fixture('linear')['outputs'] as Map<String, dynamic>,
        ),
        provider: 'coreml',
      );
      expect(report.selection, isNull);
      expect(report.actualProvider, isNull);
      expect(
        report.status,
        (Platform.isMacOS || Platform.isIOS)
            ? MlRunStatus.invalid
            : MlRunStatus.unsupported,
      );
    },
  );
  test(
    'comparative probe shares a 64MiB model budget across both workers',
    () async {
      final model = MlModelManifest.decode(
        jsonEncode({
          ...jsonDecode(_manifest('linear').encode()) as Map<String, dynamic>,
          'maxModelBytes': 64 * 1024 * 1024,
        }),
      );
      final report = await probe.probe(
        model: model,
        resolver: (_) async => Uint8List(32 * 1024 * 1024 + 1),
        inputs: _tensors(_fixture('linear')['inputs'] as Map<String, dynamic>),
        referenceOutputs: _tensors(
          _fixture('linear')['outputs'] as Map<String, dynamic>,
        ),
        provider: 'coreml',
      );
      expect(report.selection, isNull);
      expect(report.actualProvider, isNull);
      expect(
        report.status,
        (Platform.isMacOS || Platform.isIOS)
            ? MlRunStatus.unavailable
            : MlRunStatus.unsupported,
      );
      if (Platform.isMacOS || Platform.isIOS) {
        expect(report.message, contains('shared 64MiB'));
      }
    },
  );
  test(
    'a JSON qualification claim is not an executable provider token',
    () async {
      final dynamic forged = {'provider': 'coreml', 'qualified': true};
      await expectLater(
        () => runtime.load(
          _manifest('linear'),
          (path) => File('test/fixtures/$path').readAsBytes(),
          selection: forged,
        ),
        throwsA(isA<TypeError>()),
      );
    },
  );
  for (final name in ['linear', 'lstm_step', 'cnn_step']) {
    test(
      'exact $name CoreML graph is measured or rejected without CPU fallback',
      () async {
        final model = _manifest(name);
        final fixture = _fixture(name);
        final inputs = _tensors(fixture['inputs'] as Map<String, dynamic>);
        final report = await probe.probe(
          model: model,
          resolver: (path) => File('test/fixtures/$path').readAsBytes(),
          inputs: inputs,
          referenceOutputs: _tensors(
            fixture['outputs'] as Map<String, dynamic>,
          ),
          provider: 'coreml',
          sequence: name == 'lstm_step' ? _sequence() : null,
        );
        receipts[name] = {
          'status': report.status.name,
          'requested': report.requestedProvider,
          'actual': report.actualProvider,
          'message': report.message,
          'partition': report.partition?.kernels,
          'numerical': report.numericalProbeVerified,
          'sequence_steps': report.sequenceSteps,
          'benefit': report.timingBenefitVerified,
          'selection': report.selection != null,
          'hardware': report.acceleratedHardware,
          'load_us': report.modelLoad?.inMicroseconds,
          'cold_us': report.coldRun?.inMicroseconds,
          'warm_us': report.warmRun?.inMicroseconds,
          'cpu_round_trip_median_us': report.cpuRoundTripMedian?.inMicroseconds,
          'coreml_round_trip_median_us':
              report.providerRoundTripMedian?.inMicroseconds,
          'cpu_round_trip_p95_us': report.cpuRoundTripP95?.inMicroseconds,
          'coreml_round_trip_p95_us':
              report.providerRoundTripP95?.inMicroseconds,
        };
        expect(report.requestedProvider, 'coreml');
        expect(report.actualProvider, isNot('cpu'));
        expect(report.acceleratedHardware, isNull);
        if (report.status == MlRunStatus.ok) {
          expect(report.partition!.exclusivelyCoreMl, isTrue);
          expect(report.numericalProbeVerified, isTrue);
          expect(report.unsupportedOperators, isEmpty);
          if (name == 'lstm_step') expect(report.sequenceSteps, 1000);
          expect(report.selection != null, report.timingBenefitVerified);
          final selection = report.selection;
          if (selection != null) {
            expect(selection.matches(model: model), isTrue);
            expect(
              selection.matches(model: _manifest('typed_identity')),
              isFalse,
            );
            expect(
              () => selection.inputShapes['other'] = [1],
              throwsUnsupportedError,
            );
            expect(
              () => selection.inputShapes.values.first.add(7),
              throwsUnsupportedError,
            );
            final worker = MlWorker(
              providerSelections: {model.sha256: selection},
            );
            try {
              await worker.load(
                model,
                await File('test/fixtures/${model.modelFile}').readAsBytes(),
              );
              final cancel = MlCancellationToken()..cancel();
              final before = runtime.diagnostics.completedRuns;
              final cancelled = await worker.run(
                model.sha256,
                inputs,
                MlRunOptions(cancellation: cancel),
              );
              expect(cancelled.status, MlRunStatus.cancelled);
              expect(runtime.diagnostics.completedRuns, before);
              expect(
                (await worker.run(
                  model.sha256,
                  const {},
                  const MlRunOptions(),
                )).status,
                MlRunStatus.unsupported,
              );
              expect(
                (await worker.run(
                  model.sha256,
                  inputs,
                  const MlRunOptions(),
                )).status,
                MlRunStatus.ok,
              );
            } finally {
              await worker.close();
              await worker.close();
            }
          }
        } else {
          expect(report.selection, isNull);
          expect(report.timingBenefitVerified, isFalse);
          expect(report.message, isNotEmpty);
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  }
  test(
    'existing four-MatMul graph uses an independent analytic reference',
    () async {
      final model = _manifest('slow_matmul');
      final input = MlTensor.float32([
        1,
        1024,
        1024,
      ], List<double>.filled(1024 * 1024, .002));
      // Four products compute A^5. Each constant matrix entry is n^4*c^5.
      final reference = MlTensor.float32([
        1,
        1024,
        1024,
      ], List<double>.filled(1024 * 1024, 0.035184372088832));
      final report = await probe.probe(
        model: model,
        resolver: (path) => File('test/fixtures/$path').readAsBytes(),
        inputs: {'observation': input},
        referenceOutputs: {'action': reference},
        provider: 'coreml',
      );
      receipts['slow_matmul'] = {
        'status': report.status.name,
        'actual': report.actualProvider,
        'message': report.message,
        'partition': report.partition?.kernels,
        'numerical': report.numericalProbeVerified,
        'benefit': report.timingBenefitVerified,
        'selection': report.selection != null,
        'load_us': report.modelLoad?.inMicroseconds,
        'cold_us': report.coldRun?.inMicroseconds,
        'cpu_median_us': report.cpuRoundTripMedian?.inMicroseconds,
        'coreml_median_us': report.providerRoundTripMedian?.inMicroseconds,
        'cpu_p95_us': report.cpuRoundTripP95?.inMicroseconds,
        'coreml_p95_us': report.providerRoundTripP95?.inMicroseconds,
      };
      expect(report.actualProvider, isNot('cpu'));
      final selection = report.selection;
      if (selection != null) {
        expect(report.partition!.exclusivelyCoreMl, isTrue);
        expect(report.numericalProbeVerified, isTrue);
        expect(report.timingBenefitVerified, isTrue);
        final session = await runtime.load(
          model,
          (path) => File('test/fixtures/$path').readAsBytes(),
          selection: selection,
        );
        try {
          expect(session.actualProvider, 'coreml');
          expect(
            (await session.run({'observation': input})).status,
            MlRunStatus.ok,
          );
          final unqualifiedBatch = MlTensor.float32([
            2,
            1024,
            1024,
          ], List<double>.filled(2 * 1024 * 1024, .002));
          expect(
            (await session.run({'observation': unqualifiedBatch})).status,
            MlRunStatus.unsupported,
          );
        } finally {
          await session.close();
        }
        final worker = MlWorker(providerSelections: {model.sha256: selection});
        try {
          await worker.load(
            model,
            await File('test/fixtures/${model.modelFile}').readAsBytes(),
          );
          final altered = MlModelManifest.decode(
            jsonEncode({
              ...jsonDecode(model.encode()) as Map<String, dynamic>,
              'id': 'different-manifest',
            }),
          );
          expect(selection.matches(model: altered), isFalse);
          await expectLater(
            worker.load(
              altered,
              await File('test/fixtures/${model.modelFile}').readAsBytes(),
            ),
            throwsA(
              isA<MlLoadException>().having(
                (e) => e.status,
                'status',
                MlRunStatus.unsupported,
              ),
            ),
          );
          final cancel = MlCancellationToken();
          final event = worker.events.first;
          final before = runtime.diagnostics.completedRuns;
          final cancelled = worker.run(model.sha256, {
            'observation': input,
          }, MlRunOptions(cancellation: cancel));
          await event;
          cancel.cancel();
          expect((await cancelled).status, MlRunStatus.cancelled);
          expect(runtime.diagnostics.completedRuns, before + 1);
          final running = worker.run(model.sha256, {
            'observation': input,
          }, const MlRunOptions());
          final closing = worker.close();
          expect((await running).status, MlRunStatus.ok);
          await closing;
          await worker.close();
          expect((await worker.diagnostics()).liveSessions, 0);
        } finally {
          await worker.close();
        }
      } else {
        expect(report.timingBenefitVerified, isFalse);
        expect(report.message, isNotEmpty);
      }
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );
  test('incorrect independent reference can never qualify CoreML', () async {
    final report = await probe.probe(
      model: _manifest('linear'),
      resolver: (path) => File('test/fixtures/$path').readAsBytes(),
      inputs: _tensors(_fixture('linear')['inputs'] as Map<String, dynamic>),
      referenceOutputs: {
        'action': MlTensor.float32([1, 2], [0, 0]),
      },
      provider: 'coreml',
    );
    expect(report.selection, isNull);
    expect(report.numericalProbeVerified, isFalse);
    expect(report.status, isNot(MlRunStatus.ok));
  });
}
