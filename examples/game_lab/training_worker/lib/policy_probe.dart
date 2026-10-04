import 'dart:convert';
import 'dart:io';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'sequence_observations.dart';

/// Renderer-free sequence qualification through the actual native ML runtime.
Future<void> runPolicySequence(
  String source, {
  void Function(Map<String, Object?>)? publish,
}) async {
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
  final visualMatch = family is String
      ? RegExp(
          r'^(guard|vehicle)-visual-(rgb|depth|combined)$',
        ).firstMatch(family)
      : null;
  final visual = visualMatch == null
      ? null
      : TrainingVisualProfiles.forFamily(
          family: visualMatch.group(1)!,
          mode: visualMatch.group(2)!,
        );
  final multi =
      family == 'cooperative-search' || family == 'competitive-pursuit'
      ? TrainingMultiProfiles.forTask(task: family as String)
      : null;
  final guard =
      family == 'guard' || visualMatch?.group(1) == 'guard' || multi != null;
  final binary = request.containsKey('observations');
  if ((request.length !=
          (family == null
              ? 2
              : binary
              ? 4
              : 3)) ||
      (family != null &&
          family != 'guard' &&
          family != 'vehicle' &&
          visual == null &&
          multi == null) ||
      (binary && visual == null) ||
      (visual != null && !binary) ||
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
  if (visual != null &&
      (manifest.inputs.firstOrNull?.shape.last != visual.spec.width ||
          jsonEncode(manifest.preprocessing['visualProfile']) !=
              jsonEncode(visual.toJson()))) {
    throw StateError('Policy visual manifest/profile binding differs.');
  }
  if (multi != null) {
    final header = manifest.preprocessing['multiProfile'];
    if (header is! Map ||
        TrainingMultiProfiles.fromJson(header.cast<String, Object?>()).task !=
            multi.task ||
        manifest.inputs.firstOrNull?.shape.last != multi.spec.width ||
        manifest.inputs.any(
          (input) => input.name != 'observation' && input.shape.last != 128,
        ) ||
        manifest.outputs.any(
          (output) => output.shape.last != (output.name == 'logits' ? 22 : 128),
        )) {
      throw StateError('Policy multi manifest/profile binding differs.');
    }
  }
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
            s.shape[1] >
                (s.name == 'observation' && visual != null
                    ? visual.spec.width
                    : 128),
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
          observation:
              multi?.spec ??
              visual?.spec ??
              (guard
                  ? TrainingProfiles.guard().spec
                  : TrainingProfiles.vehicle().spec),
          decoder:
              multi?.decoder ??
              visual?.decoder ??
              (guard
                  ? ActionDecoder.characterDiscrete()
                  : ActionDecoder.vehiclePedals()),
          encoder: visual == null
              ? const FramePolicyEncoder()
              : VisualPolicyEncoder(visual),
          continuousOutput: guard ? null : 'action',
          discreteOutput: guard ? 'logits' : null,
        );
  final observations = binary
      ? await SequenceObservations.load(
          file,
          request['observations'],
          rows: rows.length,
          width: visual!.spec.width,
        )
      : null;
  final actorIds = <String>{};
  for (final row in rows) {
    if (row is! Map ||
        row.length !=
            ((guard ? 3 : 2) - (binary ? 1 : 0) + (multi != null ? 1 : 0)) ||
        row['reset'] is! bool ||
        (binary
            ? row.containsKey('observation')
            : row['observation'] is! List) ||
        (guard && row['legality'] is! List)) {
      throw StateError('Invalid recorded sequence row.');
    }
    if (multi != null) {
      final actor = row['actor'];
      if (actor is! String ||
          !RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$').hasMatch(actor) ||
          (row['observation'] as List).length != multi.spec.width) {
        throw StateError('Invalid multi actor observation row.');
      }
      final values = row['observation'] as List;
      final masks = row['legality'] as List;
      if (values.any((value) => value is! num || !value.isFinite) ||
          masks.length != multi.decoder.spec.branches.length) {
        throw StateError('Invalid multi observation or legality.');
      }
      for (var branch = 0; branch < masks.length; branch++) {
        final mask = masks[branch];
        if (mask is! List ||
            mask.length != multi.decoder.spec.branches[branch].choices.length ||
            mask.any((value) => value is! bool) ||
            !mask.contains(true)) {
          throw StateError('Invalid multi legality branch.');
        }
      }
      // Full profile v2 pins body grounded at3 and its validity at16. These
      // service masks cannot enable interaction or invent known grounding.
      if ((masks[5] as List)[1] == true ||
          (masks[4] as List)[1] == true &&
              (values[3] != 1 || values[16] != 1)) {
        throw StateError('Multi action mask contradicts permitted body input.');
      }
      actorIds.add(actor);
      if (actorIds.length > 64) {
        throw StateError('Multi sequence actor budget exceeded.');
      }
    }
  }
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
  final actorStates = <String, (MlTensor, MlTensor)>{};
  try {
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index] as Map;
      if (multi != null) {
        final previous = actorStates[row['actor'] as String];
        hidden =
            previous?.$1 ??
            MlTensor.float32([1, hiddenWidth], List.filled(hiddenWidth, 0));
        cell =
            previous?.$2 ??
            MlTensor.float32([1, cellWidth], List.filled(cellWidth, 0));
      }
      if (row['reset'] == true) {
        hidden = MlTensor.float32([
          1,
          hiddenWidth,
        ], List.filled(hiddenWidth, 0));
        cell = MlTensor.float32([1, hiddenWidth], List.filled(hiddenWidth, 0));
      }
      final observation =
          observations?.row(index) ?? (row['observation'] as List).cast<num>();
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
        final legality = guard
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
      if (multi != null) actorStates[row['actor'] as String] = (hidden, cell);
    }
  } finally {
    await session.close();
  }
  final diagnostics = runtime.diagnostics;
  final receipt = <String, Object?>{
    'schema_version': 1,
    'model_sha256': manifest.sha256,
    'provider': 'native-onnxruntime-${manifest.runtimeVersion}-cpu',
    'completed_runs': diagnostics.completedRuns - before,
    'live_sessions': diagnostics.liveSessions,
    'live_results': diagnostics.liveResults,
    'outputs': outputs,
    if (observations != null) 'input_observations': observations.descriptor,
    if (contract != null) 'actions': actions,
  };
  if (publish == null) {
    stdout.writeln(jsonEncode(receipt));
  } else {
    publish(receipt);
  }
}
