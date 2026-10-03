import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_game_ai/artifact.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';

Uint8List jsonBytes(Object value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(value)));
String digest(List<int> bytes) => sha256.convert(bytes).toString();

// Synthetic codec data is never loaded as ONNX or published as a trained model.
final class CodecFixture {
  final files = <String, Uint8List>{};
  late final Map<String, Object?> bundle;
  CodecFixture({bool syntheticModelEvaluation = true}) {
    final root = Directory('packages/zyren_game_ai').existsSync()
        ? ''
        : '../../';
    final report =
        jsonDecode(
              File(
                '${root}packages/zyren_game_studio/test/fixtures/passed-checkpoint-evaluation-v4.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    final observation = TrainingProfiles.guard().spec,
        action = TrainingActions.character;
    final bytes = Uint8List.fromList([7]);
    final hash = digest(bytes),
        normalizationHash = 'a' * 64,
        sourceHash = 'b' * 64;
    MlTensorSpec spec(String name, int width) => MlTensorSpec(
      name: name,
      dtype: MlDtype.float32,
      shape: [-1, width],
      maxShape: [64, width],
    );
    final model = MlModelManifest(
      id: 'codec-fixture',
      modelFile: 'actor.onnx',
      sha256: hash,
      opset: 17,
      inputs: [
        spec('observation', observation.width),
        spec('hidden', 128),
        spec('cell', 128),
      ],
      outputs: [
        spec('logits', 22),
        spec('next_hidden', 128),
        spec('next_cell', 128),
      ],
      recurrent: {'hidden': 'next_hidden', 'cell': 'next_cell'},
      preprocessing: {
        'normalization': 'embedded-mean-scale-v1',
        'sourceHash': normalizationHash,
      },
    );
    if (syntheticModelEvaluation) report['family_model_hashes']['guard'] = hash;
    files.addAll({
      'actor.onnx': bytes,
      'model.json': Uint8List.fromList(utf8.encode(model.encode())),
      'observation.json': jsonBytes(observation.toJson()),
      'action.json': jsonBytes(action.toJson()),
      'normalization.json': jsonBytes({
        'schema_version': 1,
        'mode': 'embedded-mean-scale-v1',
        'mean': List.filled(observation.width, 0.0),
        'scale': List.filled(observation.width, 1.0),
        'source_hash': normalizationHash,
      }),
      'recurrent.json': jsonBytes({
        'schema_version': 1,
        'inputs': {
          'hidden': [128],
          'cell': [128],
        },
        'outputs': {'hidden': 'next_hidden', 'cell': 'next_cell'},
        'reset': 'zero',
        'max_batch': 64,
        'dtype': 'float32',
      }),
      'provenance.json': jsonBytes({
        'schema_version': 1,
        'source_checkpoint_sha256': sourceHash,
        'training_config_hash': 'c' * 64,
        'training_worker_sha256': 'd' * 64,
        'training_source_pins': <String, Object?>{},
        'training_native_sha256': <String, Object?>{},
        'license': 'LicenseRef-Repository-Authored',
        'optimizer_exported': false,
        'critic_exported': false,
      }),
      'evaluation.json': jsonBytes(report),
    });
    bundle = {
      'schema_version': 1,
      'id': 'codec-fixture',
      'family': 'guard',
      'model_sha256': hash,
      'source_checkpoint_sha256': sourceHash,
      'observation_schema_hash': observation.hash,
      'action_schema_hash': action.hash,
      'controller_mapping': 'character-discrete-v1',
      'evaluation_report_hash': digest(files['evaluation.json']!),
      'evaluation_plan_hash': report['plan_hash'],
      'precision': 'float32',
      'provider': 'cpu',
      'accepted': true,
      'policy': {
        'observation_input': 'observation',
        'continuous_output': null,
        'discrete_output': 'logits',
        'recurrent': {'hidden': 'next_hidden', 'cell': 'next_cell'},
        'cadence_ticks': 1,
        'latency_ticks': 1,
        'max_hold_ticks': 0,
      },
    };
  }
  Uint8List get manifest => jsonBytes({
    ...bundle,
    'files': [
      for (final e in files.entries)
        {'path': e.key, 'bytes': e.value.length, 'sha256': digest(e.value)},
    ],
  });
}

void main() {
  test(
    'synthetic codec validates contracts and owns returned metadata bytes',
    () {
      final f = CodecFixture();
      final artifact = ModelArtifact.decode(f.manifest, f.files);
      expect(artifact.contract.encoder, isA<FramePolicyEncoder>());
      expect(
        artifact.contract.decoder.spec.hash,
        TrainingActions.character.hash,
      );
      expect(artifact.evaluation.accepted, isTrue);
      expect(artifact.fixedHz, 50);
      f.files['actor.onnx']![0] = 9;
      expect(artifact.files['actor.onnx'], [7]);
      expect(
        () => artifact.files['actor.onnx']![0] = 8,
        throwsUnsupportedError,
      );
      expect(
        () => artifact.evaluation.cases.first['seeds'] = [],
        throwsUnsupportedError,
      );
    },
  );
  test(
    'actual checkpoint report cannot establish acceptance of another model',
    () {
      final f = CodecFixture(syntheticModelEvaluation: false);
      expect(
        () => ModelArtifact.decode(f.manifest, f.files),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'reason',
            contains('Evaluation'),
          ),
        ),
      );
    },
  );
  test(
    'bundle rejects missing resources, altered hashes and invalid normalization',
    () {
      expect(
        () => ModelArtifact.decode(jsonBytes({}), {}),
        throwsFormatException,
      );
      final f = CodecFixture(), original = f.manifest;
      f.files['actor.onnx']![0] = 8;
      expect(
        () => ModelArtifact.decode(original, f.files),
        throwsFormatException,
      );
      final invalid = CodecFixture();
      final normalization =
          jsonDecode(utf8.decode(invalid.files['normalization.json']!)) as Map;
      normalization['scale'][0] = 0;
      invalid.files['normalization.json'] = jsonBytes(normalization);
      expect(
        () => ModelArtifact.decode(invalid.manifest, invalid.files),
        throwsFormatException,
      );
    },
  );
}
