import 'dart:convert';
import 'dart:io';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

/// Renderer-free sequence qualification through the actual native ML runtime.
Future<void> runPolicySequence(String source) async {
  final file = File(source);
  if (await file.length() > 1048576) {
    throw StateError('Policy sequence input exceeds byte budget.');
  }
  final bytes = await file.readAsBytes();
  var depth = 0, quoted = false, escape = false;
  for (final byte in bytes) {
    if (quoted) {
      if (escape) {
        escape = false;
      } else if (byte == 92) {
        escape = true;
      } else if (byte == 34) {
        quoted = false;
      }
    } else if (byte == 34) {
      quoted = true;
    } else if (byte == 91 || byte == 123) {
      if (++depth > 16) {
        throw StateError('Policy sequence depth exceeds budget.');
      }
    } else if (byte == 93 || byte == 125) {
      depth--;
    }
  }
  final request = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
  final family = request['family'];
  if ((request.length != (family == null ? 2 : 3)) ||
      (family != null && family != 'guard' && family != 'vehicle') ||
      request['manifest'] is! String ||
      request['rows'] is! List) {
    throw StateError('Invalid policy sequence request.');
  }
  final rows = request['rows'] as List;
  if (rows.isEmpty || rows.length > 2000) {
    throw StateError('Policy sequence row budget differs.');
  }
  final manifestFile = File(request['manifest'] as String);
  if (await manifestFile.length() > 65536) {
    throw StateError('Policy manifest byte budget differs.');
  }
  final manifest = MlModelManifest.decode(await manifestFile.readAsString());
  if (manifest.inputs.length != 3 ||
      manifest.inputs[0].name != 'observation' ||
      manifest.recurrent.length != 2 ||
      manifest.recurrent['hidden'] != 'next_hidden' ||
      manifest.recurrent['cell'] != 'next_cell' ||
      manifest.inputs.any(
        (s) =>
            s.dtype != MlDtype.float32 ||
            s.shape.length != 2 ||
            s.shape[1] < 1 ||
            s.shape[1] > 128,
      ) ||
      manifest.outputs.length != 3 ||
      manifest.outputs.any(
        (s) =>
            s.dtype != MlDtype.float32 ||
            s.shape.length != 2 ||
            s.shape[1] < 1 ||
            s.shape[1] > 128,
      )) {
    throw StateError('Policy recurrent sequence binding differs.');
  }
  final hiddenWidth = manifest.inputs
      .singleWhere((s) => s.name == 'hidden')
      .shape[1];
  final cellWidth = manifest.inputs
      .singleWhere((s) => s.name == 'cell')
      .shape[1];
  if (hiddenWidth < 1 || hiddenWidth > 128 || cellWidth != hiddenWidth) {
    throw StateError('Policy state width exceeds sequence budget.');
  }
  final contract = family == null
      ? null
      : PolicyContract(
          model: manifest,
          observation: family == 'guard'
              ? TrainingProfiles.guard().spec
              : TrainingProfiles.vehicle().spec,
          decoder: family == 'guard'
              ? ActionDecoder.characterDiscrete()
              : ActionDecoder.vehiclePedals(),
          continuousOutput: family == 'guard' ? null : 'action',
          discreteOutput: family == 'guard' ? 'logits' : null,
        );
  const runtime = MlRuntime();
  final before = runtime.diagnostics.completedRuns;
  final session = await runtime.load(
    manifest,
    (path) => File('${manifestFile.parent.path}/$path').readAsBytes(),
  );
  final outputs = <Map<String, Object?>>[];
  final actions = <Map<String, Object?>>[];
  var hidden = MlTensor.float32([1, hiddenWidth], List.filled(hiddenWidth, 0));
  var cell = MlTensor.float32([1, hiddenWidth], List.filled(hiddenWidth, 0));
  try {
    for (final row in rows) {
      if (row is! Map ||
          row.length != (family == 'guard' ? 3 : 2) ||
          row['reset'] is! bool ||
          row['observation'] is! List) {
        throw StateError('Invalid recorded sequence row.');
      }
      if (row['reset'] == true) {
        hidden = MlTensor.float32([
          1,
          hiddenWidth,
        ], List.filled(hiddenWidth, 0));
        cell = MlTensor.float32([1, hiddenWidth], List.filled(hiddenWidth, 0));
      }
      final observation = (row['observation'] as List).cast<num>();
      final result = await session.run({
        'observation': MlTensor.float32([1, observation.length], observation),
        'hidden': hidden,
        'cell': cell,
      });
      if (result.status != MlRunStatus.ok) {
        throw StateError('Native policy execution failed: ${result.message}');
      }
      outputs.add({
        for (final entry in result.tensors.entries)
          entry.key: {
            'dtype': 'float32',
            'shape': entry.value.shape,
            'data': base64Encode(entry.value.bytes),
          },
      });
      if (contract != null) {
        final legality = family == 'guard'
            ? (row['legality'] as List)
                  .map((branch) => (branch as List).cast<bool>())
                  .toList()
            : null;
        final decoded = contract.decodeOutputs(
          result.tensors,
          legality: legality,
        );
        if (decoded == null) {
          throw StateError('Native typed controller rejected output.');
        }
        actions.add({
          'continuous': decoded.action.continuous,
          'discrete': decoded.action.discrete,
        });
      }
      hidden = result.tensors['next_hidden']!;
      cell = result.tensors['next_cell']!;
    }
  } finally {
    await session.close();
  }
  final diagnostics = runtime.diagnostics;
  stdout.writeln(
    jsonEncode({
      'schema_version': 1,
      'model_sha256': manifest.sha256,
      'provider': 'native-onnxruntime-${manifest.runtimeVersion}-cpu',
      'completed_runs': diagnostics.completedRuns - before,
      'live_sessions': diagnostics.liveSessions,
      'live_results': diagnostics.liveResults,
      'outputs': outputs,
      if (contract != null) 'actions': actions,
    }),
  );
}
