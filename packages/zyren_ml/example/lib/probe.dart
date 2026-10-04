import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:zyren_ml/zyren_ml.dart';

/// Runs the exported local fixtures through the real isolate-owned C API.
Future<Map<String, Object?>> runNativeProbe({
  void Function(String)? progress,
}) async {
  final worker = MlWorker();
  final clock = Stopwatch()..start();
  var maxError = 0.0;
  Future<Uint8List> bytes(String name) async =>
      (await rootBundle.load('assets/$name')).buffer.asUint8List();
  Future<dynamic> json(String name) async =>
      jsonDecode(await rootBundle.loadString('assets/$name'));
  Future<MlModelManifest> model(String name) async =>
      MlModelManifest.decode(await rootBundle.loadString('assets/$name.json'));
  MlTensorMap inputs(Map value) => {
    for (final MapEntry entry in (value['inputs'] as Map).entries)
      entry.key as String: MlTensor.float32(
        (entry.value['shape'] as List).cast<int>(),
        (entry.value['values'] as List).cast<num>(),
      ),
  };
  void compare(MlRunResult result, Map expected) {
    if (result.status != MlRunStatus.ok) {
      throw StateError(
        'Native run failed: ${result.status.name}, ${result.message}',
      );
    }
    for (final MapEntry entry in expected.entries) {
      final reference = entry.value is Map
          ? entry.value['values'] as List
          : entry.value as List;
      final actual = result.tensors[entry.key]!.float32Values;
      if (actual.length != reference.length) {
        throw StateError('Output length changed.');
      }
      for (var i = 0; i < actual.length; i++) {
        final error = (actual[i] - (reference[i] as num).toDouble()).abs();
        if (error > maxError) maxError = error;
        if (!actual[i].isFinite ||
            error > 1e-5 + 1e-4 * (reference[i] as num).abs()) {
          throw StateError('Parity failed at ${entry.key}[$i]: $error.');
        }
      }
    }
  }

  try {
    final linear = await model('linear'),
        linearBytes = await bytes('linear.onnx');
    final linearValues = await json('linear.values.json') as Map;
    progress?.call('30 real load/run/release cycles');
    for (var cycle = 0; cycle < 30; cycle++) {
      await worker.load(linear, linearBytes);
      compare(
        await worker.run(
          linear.sha256,
          inputs(linearValues),
          MlRunOptions(requestId: 'linear/$cycle'),
        ),
        linearValues['outputs'] as Map,
      );
      await worker.release(linear.sha256);
      final state = await worker.diagnostics();
      if (state.liveSessions != 0 || state.liveResults != 0) {
        throw StateError('Native cycle leaked a handle.');
      }
    }
    final recurrent = await model('lstm_step');
    await worker.load(recurrent, await bytes('lstm_step.onnx'));
    final initial = await json('lstm_step.values.json') as Map;
    var state = inputs(initial);
    final sequence = await json('lstm_sequence.values.json') as List;
    if (sequence.length != 1000) {
      throw StateError('The pinned sequence must contain 1000 steps.');
    }
    progress?.call('1000 native recurrent steps, including resets');
    for (var step = 0; step < sequence.length; step++) {
      final row = sequence[step] as Map;
      if (row['reset'] == true) state = inputs(initial);
      state['observation'] = MlTensor.float32([
        1,
        4,
      ], (row['observation'] as List).cast<num>());
      final result = await worker.run(
        recurrent.sha256,
        state,
        MlRunOptions(requestId: 'lstm/$step'),
      );
      compare(result, row['outputs'] as Map);
      state = {
        'observation': state['observation']!,
        'hidden': result.tensors['next_hidden']!,
        'cell': result.tensors['next_cell']!,
      };
    }
    final before = (await worker.diagnostics()).completedRuns;
    final expired = await worker.run(
      recurrent.sha256,
      state,
      MlRunOptions(deadline: DateTime.fromMillisecondsSinceEpoch(0)),
    );
    if (expired.status != MlRunStatus.cancelled ||
        (await worker.diagnostics()).completedRuns != before) {
      throw StateError('Expired request entered native execution.');
    }
    await worker.release(recurrent.sha256);
    progress?.call('CNN84x84 and exact int64/bool native tensors');
    final cnn = await model('cnn_step'),
        cnnValues = await json('cnn_step.values.json') as Map;
    await worker.load(cnn, await bytes('cnn_step.onnx'));
    compare(
      await worker.run(cnn.sha256, inputs(cnnValues), const MlRunOptions()),
      cnnValues['outputs'] as Map,
    );
    await worker.release(cnn.sha256);
    final typed = await model('typed_identity');
    await worker.load(typed, await bytes('typed_identity.onnx'));
    final result = await worker.run(typed.sha256, {
      'ids': MlTensor.int64([2, 2], [-7, 1 << 40, 3, 42]),
      'mask': MlTensor(MlDtype.bool, [2, 2], Uint8List.fromList([1, 0, 0, 1])),
    }, const MlRunOptions());
    if (result.status != MlRunStatus.ok ||
        jsonEncode(result.tensors['next_ids']!.int64Values) !=
            jsonEncode([-7, 1 << 40, 3, 42]) ||
        jsonEncode(result.tensors['next_mask']!.boolValues) !=
            jsonEncode([true, false, false, true])) {
      throw StateError('Native typed tensor values changed.');
    }
    await worker.release(typed.sha256);
    final corrupt = Uint8List.fromList(linearBytes)..[0] ^= 1;
    var rejected = false;
    try {
      await worker.load(linear, corrupt);
    } catch (_) {
      rejected = true;
    }
    if (!rejected) throw StateError('Corrupt model was accepted.');
    await worker.close();
    final diagnostics = await worker.diagnostics();
    if (diagnostics.liveSessions != 0 ||
        diagnostics.liveResults != 0 ||
        diagnostics.completedRuns != 1032) {
      throw StateError('Native final counters differ.');
    }
    return {
      'schema_version': 1,
      'status': 'passed',
      'platform': Platform.operatingSystem,
      'runtime': MlRuntime.runtimeVersion,
      'provider': 'cpu',
      'completed_runs': diagnostics.completedRuns,
      'recurrent_steps': 1000,
      'load_run_close_cycles': 30,
      'live_sessions': diagnostics.liveSessions,
      'live_results': diagnostics.liveResults,
      'worker_isolate': diagnostics.ownerIsolateId,
      'max_absolute_error': maxError,
      'atol': 1e-5,
      'rtol': 1e-4,
      'expired_request_skipped': true,
      'corrupt_model_rejected': true,
      'elapsed_ms': clock.elapsedMilliseconds,
      'native_arena_bytes': null,
      'model_hashes': {
        'linear': linear.sha256,
        'lstm': recurrent.sha256,
        'cnn': cnn.sha256,
        'typed': typed.sha256,
      },
    };
  } finally {
    await worker.close();
  }
}
