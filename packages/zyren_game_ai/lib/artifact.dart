/// Shared byte-only model and held-out evaluation validation for game hosts.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'zyren_game_ai.dart';

const structuredModelEvaluationPlanHashes = {
  '70293bb2509acec9f3626a87423f5a077d496e75cad3dc734f6fff853af763c4',
  'deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd',
};

/// Exact frozen visual plans. Registration does not qualify any student model.
const visualModelEvaluationPlanHashes = <String, Set<String>>{
  'rgb': {'55d7313ed3e2695364afcd21c5afbd47bfaebd4e4cac26b484b801b06f9b149f'},
  'depth': {'d347818a1e38e1ddc8be7467a5b43dab4f8efcd2cbc0894864ed29bd655aae6d'},
  'combined': {
    'c256c2036fdaf2cb2e65c3986ee6d75ab70883cdeb2980e430cd18fc5d144f68',
  },
};

TrainingVisualProfile? _artifactVisualProfile(String family) {
  if (family == 'guard' || family == 'vehicle') return null;
  final match = RegExp(
    r'^(guard|vehicle)-visual-(rgb|depth|combined)$',
  ).firstMatch(family);
  if (match == null) throw const FormatException('Unknown model family.');
  return TrainingVisualProfiles.forFamily(family: match[1]!, mode: match[2]!);
}

bool _artifactDigest(Object? value) =>
    value is String && RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
Object? _artifactFrozen(Object? value) {
  if (value is List) {
    return List<Object?>.unmodifiable(value.map(_artifactFrozen));
  }
  if (value is Map) {
    return Map<String, Object?>.unmodifiable(
      value.map((k, v) => MapEntry(k as String, _artifactFrozen(v))),
    );
  }
  return value;
}

final class ModelEvaluation {
  final String modelHash, observationHash, actionHash, receiptHash, planHash;
  final List<Map<String, Object?>> cases;
  final bool accepted;
  final String provider;
  final int fixedHz;
  final double successRate;
  final String? supersededPlanHash;
  ModelEvaluation._({
    required this.modelHash,
    required this.observationHash,
    required this.actionHash,
    required this.receiptHash,
    required this.planHash,
    required this.accepted,
    required this.provider,
    required this.fixedHz,
    required this.successRate,
    this.supersededPlanHash,
    required List<Map<String, Object?>> cases,
  }) : cases = List.unmodifiable(
         cases.map((c) => _artifactFrozen(c) as Map<String, Object?>),
       );
  factory ModelEvaluation.decode(
    Uint8List bytes, {
    required String receiptHash,
    required String family,
    required String modelHash,
    required String observationHash,
    required String actionHash,
  }) {
    if (!['guard', 'vehicle'].contains(family) ||
        ![
          receiptHash,
          modelHash,
          observationHash,
          actionHash,
        ].every(_artifactDigest) ||
        bytes.length > 16777216 ||
        sha256.convert(bytes).toString() != receiptHash) {
      throw FormatException('Evaluation receipt size or pins differ.');
    }
    final raw = utf8.decode(bytes);
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final plan = data['plan'] as Map<String, dynamic>,
        cases = plan['cases'] as List,
        episodes = data['episodes'] as List;
    if (data['schema_version'] != 1 ||
        !['passed', 'failed'].contains(data['status']) ||
        !_artifactDigest(data['plan_hash']) ||
        data['provider'] is! String ||
        (data['provider'] as String).isEmpty ||
        [
          'worker_failures',
          'hidden_state_leaks',
          'reward_exploits',
        ].any((k) => data[k] is! int || data[k] < 0) ||
        plan['schema_version'] != 1 ||
        cases.isEmpty ||
        cases.length > 64 ||
        episodes.length > 20000 ||
        sha256.convert(utf8.encode(_rawJsonField(raw, 'plan'))).toString() !=
            data['plan_hash'] ||
        data['worker_sha256'] != plan['worker_sha256'] ||
        jsonEncode(data['worker_native_sha256']) !=
            jsonEncode(plan['worker_native_sha256']) ||
        !_artifactDigest(data['worker_sha256']) ||
        data['family_model_hashes'][family] != modelHash) {
      throw FormatException('Evaluation plan/model/worker identity differs.');
    }
    if (plan['revision'] case final Map revision) {
      final rawPlan = _rawJsonField(raw, 'plan');
      final fields = [
        'cases',
        'paired_worlds',
        'targets',
        'training_scenario_hashes',
      ].map((k) => '"$k":${_rawJsonField(rawPlan, k)}').join(',');
      final content = '{$fields}';
      if (revision.length != 3 ||
          !_artifactDigest(revision['supersedes']) ||
          revision['reason'] !=
              'original executable overwritten during sequence-probe rebuild' ||
          revision['case_content_hash'] !=
              sha256.convert(utf8.encode(content)).toString()) {
        throw FormatException('Evaluation artifact revision lineage differs.');
      }
    }
    const targets = {
      'guard': {
        'collision_rate': null,
        'success_lower95': .85,
        'success_rate': .9,
      },
      'vehicle': {
        'collision_rate': .02,
        'success_lower95': .9,
        'success_rate': .95,
      },
    };
    if (jsonEncode(plan['targets']) != jsonEncode(targets)) {
      throw FormatException('Evaluation gates changed.');
    }
    int? fixedHz;
    var index = 0;
    final counts = <String, List<Map<String, dynamic>>>{
      'guard': [],
      'vehicle': [],
    };
    for (final caseValue in cases) {
      final c = caseValue as Map<String, dynamic>,
          spec = c['scenario'] as Map<String, dynamic>;
      final actorFamily = c['family'] as String;
      if (!counts.containsKey(actorFamily) || spec['partition'] != 'test') {
        throw FormatException('Evaluation case is not held out.');
      }
      if (actorFamily == family &&
          (spec['observation_schema_hash'] != observationHash ||
              spec['action_schema_hash'] != actionHash)) {
        throw FormatException('Evaluation schema changed or was reordered.');
      }
      final hz = (spec['settings'] as Map)['fixed_hz'];
      if (hz is! int ||
          hz < 10 ||
          hz > 240 ||
          spec['control_cadence'] != 1 ||
          spec['latency_ticks'] != 1) {
        throw FormatException('Evaluation fixed-step timing differs.');
      }
      if (actorFamily == family) {
        if (fixedHz != null && fixedHz != hz) {
          throw FormatException('Evaluation family mixes fixed-step rates.');
        }
        fixedHz = hz;
      }
      for (final seed in c['seeds'] as List) {
        if (index >= episodes.length) {
          throw FormatException('Evaluation dropped requested episode slots.');
        }
        final row = episodes[index] as Map<String, dynamic>;
        if (row['index'] != index ||
            row['family'] != actorFamily ||
            row['scenario'] != spec['id'] ||
            row['seed'] != seed ||
            row['success'] is! bool ||
            row['collision'] is! bool ||
            row['steps'] is! int ||
            row['steps'] < 0 ||
            !['completed', 'failed', 'cancelled'].contains(row['status']) ||
            row['success'] == true && row['status'] != 'completed') {
          throw FormatException('Evaluation episode identity differs.');
        }
        counts[actorFamily]!.add(row);
        index++;
      }
    }
    if (index != episodes.length || index != data['requested']) {
      throw FormatException('Evaluation denominator differs.');
    }
    var accepted =
        data['status'] == 'passed' &&
        data['hidden_state_leaks'] == 0 &&
        data['reward_exploits'] == 0 &&
        data['worker_failures'] == 0 &&
        (data['worker_exit_codes'] as List).isNotEmpty &&
        (data['worker_exit_codes'] as List).every((v) => v == 0);
    const coverage = {
      'unfamiliar-layouts',
      'moving-target',
      'friction',
      'occlusion-memory',
      'moving-hazards',
      'missed-decisions',
      'delayed-observations',
      'fallback-recovery',
    };
    final labels = (data['stress_coverage'] as List).cast<String>().toSet();
    accepted = accepted && labels.containsAll(coverage);
    for (final entry in counts.entries) {
      final rows = entry.value;
      if (rows.isEmpty) throw FormatException('Actor family is missing.');
      final successes = rows.where((e) => e['success'] == true).length;
      final collisions = rows.where((e) => e['collision'] == true).length;
      final metrics = data['metrics'][entry.key] as Map<String, dynamic>;
      final low = _wilsonLower(successes, rows.length);
      if (metrics['requested'] != rows.length ||
          metrics['successes'] != successes ||
          metrics['collisions'] != collisions ||
          metrics['success_denominator'] != rows.length ||
          metrics['collision_denominator'] != rows.length ||
          ((metrics['success_rate'] as num).toDouble() -
                      successes / rows.length)
                  .abs() >
              1e-12 ||
          ((metrics['success_lower95'] as num).toDouble() - low).abs() >
              1e-12) {
        throw FormatException('Evaluation aggregate was altered.');
      }
      final seeds = rows.map((e) => e['seed']).toSet().length;
      if (data['layout_seed_counts'][entry.key] != seeds) {
        throw FormatException('Layout-seed coverage differs.');
      }
      accepted =
          accepted &&
          rows.length >= 200 &&
          seeds >= 20 &&
          rows.every(
            (e) =>
                e['status'] == 'completed' &&
                e['steps'] > 0 &&
                e['invalid_actions'] == 0,
          ) &&
          successes / rows.length >= (entry.key == 'guard' ? .9 : .95) &&
          low >= (entry.key == 'guard' ? .85 : .9) &&
          (entry.key != 'vehicle' || collisions / rows.length <= .02);
    }
    if (data['status'] == 'passed' && !accepted) {
      throw FormatException('Receipt claims acceptance but fixed gates fail.');
    }
    return ModelEvaluation._(
      modelHash: modelHash,
      observationHash: observationHash,
      actionHash: actionHash,
      receiptHash: receiptHash,
      planHash: data['plan_hash'] as String,
      accepted: accepted,
      provider: data['provider'] as String,
      fixedHz: fixedHz!,
      successRate: (data['metrics'][family]['success_rate'] as num).toDouble(),
      supersededPlanHash: (plan['revision'] as Map?)?['supersedes'] as String?,
      cases: [
        for (final c in cases.where((v) => v['family'] == family))
          Map<String, Object?>.from(c),
      ],
    );
  }
}

double _wilsonLower(int successes, int count) {
  if (successes == 0) return 0;
  const z = 1.959963984540054;
  final p = successes / count, denominator = 1 + z * z / count;
  final center = (p + z * z / (2 * count)) / denominator;
  final radius =
      z *
      math.sqrt(p * (1 - p) / count + z * z / (4 * count * count)) /
      denominator;
  return math.max(0, center - radius);
}

String _rawJsonField(String json, String field) {
  var depth = 0, quoted = false, escaped = false, start = -1;
  for (var i = 0; i < json.length; i++) {
    final c = json[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
      continue;
    }
    if (c == '"') {
      if (depth == 1 && json.startsWith('"$field":', i)) {
        start = i + field.length + 3;
        break;
      }
      quoted = true;
    } else if (c == '{' || c == '[') {
      depth++;
    } else if (c == '}' || c == ']') {
      depth--;
    }
  }
  if (start < 0 || !['{', '['].contains(json[start])) {
    throw FormatException('Canonical embedded plan missing.');
  }
  depth = 0;
  quoted = false;
  escaped = false;
  for (var i = start; i < json.length; i++) {
    final c = json[i];
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == '\\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
      continue;
    }
    if (c == '"') {
      quoted = true;
    } else if (c == '{' || c == '[') {
      depth++;
    } else if (c == '}' || c == ']') {
      if (--depth == 0) return json.substring(start, i + 1);
    }
  }
  throw FormatException('Embedded plan ended mid-object.');
}

/// Validated accepted bundle metadata. Native graph loading remains cache-owned.
/// Normalization is embedded in ONNX; the raw frame encoder runs exactly once.
final class ModelArtifact {
  final String id, family, sourceCheckpointHash, precision;
  final PolicyContract contract;
  final ModelEvaluation evaluation;
  final Map<String, Uint8List> files;
  final Uint8List manifestBytes;
  ModelArtifact._(
    this.id,
    this.family,
    this.sourceCheckpointHash,
    this.precision,
    this.contract,
    this.evaluation,
    Uint8List manifest,
    Map<String, Uint8List> files,
  ) : manifestBytes = Uint8List.fromList(manifest).asUnmodifiableView(),
      files = Map.unmodifiable(
        files.map(
          (k, v) => MapEntry(k, Uint8List.fromList(v).asUnmodifiableView()),
        ),
      );
  int get fixedHz => evaluation.fixedHz;
  TrainingVisualProfile? get visualProfile =>
      contract.encoder is VisualPolicyEncoder
      ? (contract.encoder as VisualPolicyEncoder).profile
      : null;
  String get controllerFamily => visualProfile?.family ?? family;
  static const fileNames = {
    'actor.onnx',
    'model.json',
    'observation.json',
    'action.json',
    'normalization.json',
    'recurrent.json',
    'provenance.json',
    'evaluation.json',
  };
  factory ModelArtifact.decode(
    Uint8List manifest,
    Map<String, Uint8List> files,
  ) {
    if (manifest.length > 65536 ||
        files.length != fileNames.length ||
        !files.keys.toSet().containsAll(fileNames)) {
      throw FormatException('Model artifact files or manifest budget differ.');
    }
    final data = jsonDecode(utf8.decode(manifest)) as Map<String, dynamic>;
    _validateArtifactEnvelope(data);
    if (data['precision'] == 'float16') {
      throw FormatException('Float16 qualification is unavailable.');
    }
    final entries = data['files'] as List;
    if (entries.length != fileNames.length) {
      throw FormatException('Model file manifest differs.');
    }
    final seen = <String>{};
    var total = 0;
    for (final entry in entries) {
      final item = entry as Map<String, dynamic>, path = item['path'] as String;
      final bytes = files[path];
      if (item.length != 3 ||
          !seen.add(path) ||
          bytes == null ||
          bytes.isEmpty ||
          bytes.length >
              (path == 'actor.onnx'
                  ? 8388608
                  : path == 'evaluation.json'
                  ? 16777216
                  : 1048576) ||
          item['bytes'] != bytes.length ||
          sha256.convert(bytes).toString() != item['sha256']) {
        throw FormatException('Model resource size/hash differs.');
      }
      total += bytes.length;
      if (total > 33554432) {
        throw FormatException('Model artifact byte budget exceeded.');
      }
    }
    Map<String, dynamic> read(String name) =>
        jsonDecode(utf8.decode(files[name]!)) as Map<String, dynamic>;
    final model = MlModelManifest.decode(utf8.decode(files['model.json']!));
    final family = data['family'] as String;
    final visual = _artifactVisualProfile(family);
    final controllerFamily = visual?.family ?? family;
    if (visual != null && data['precision'] != 'float32') {
      throw const FormatException(
        'Visual precision qualification is unavailable.',
      );
    }
    final observation =
        visual?.spec ??
        (controllerFamily == 'guard'
                ? TrainingProfiles.guard()
                : TrainingProfiles.vehicle())
            .spec;
    final decoder = controllerFamily == 'guard'
        ? ActionDecoder.characterDiscrete()
        : ActionDecoder.vehiclePedals();
    if (model.modelFile != 'actor.onnx' ||
        model.sha256 != data['model_sha256'] ||
        model.sha256 != sha256.convert(files['actor.onnx']!).toString() ||
        model.opset != 17 ||
        model.customOperatorLibraries.isNotEmpty ||
        model.externalData.isNotEmpty ||
        files['actor.onnx']!.length > model.maxModelBytes ||
        model.runtimeVersion != '1.23.2' ||
        model.providers.length != 1 ||
        model.providers.single != 'cpu' ||
        observation.hash != data['observation_schema_hash'] ||
        decoder.spec.hash != data['action_schema_hash'] ||
        jsonEncode(read('observation.json')) !=
            jsonEncode(observation.toJson()) ||
        jsonEncode(read('action.json')) != jsonEncode(decoder.spec.toJson()) ||
        data['controller_mapping'] != decoder.spec.id) {
      throw FormatException('Model/schema/controller binding differs.');
    }
    if (files['provenance.json']!.length > 262144) {
      throw FormatException('Provenance byte budget exceeded.');
    }
    final normalization = read('normalization.json'),
        recurrent = read('recurrent.json'),
        provenance = read('provenance.json');
    final mean = normalization['mean'] as List,
        scale = normalization['scale'] as List;
    final normalizationMode = visual == null
        ? 'embedded-mean-scale-v1'
        : 'embedded-camera-body-affine-v1';
    final normalizationWidth = visual?.bodyWidth ?? observation.width;
    if (visual != null) {
      const normKeys = {
        'schema_version',
        'mode',
        'camera_width',
        'mean',
        'scale',
        'source_hash',
      };
      final header = model.preprocessing['visualProfile'];
      final input = model.inputs
          .where((s) => s.name == 'observation')
          .firstOrNull;
      if (header is! Map ||
          TrainingVisualProfiles.fromJson(
                Map<String, Object?>.from(header),
              ).configurationHash !=
              visual.configurationHash ||
          normalization.length != normKeys.length ||
          !normalization.keys.toSet().containsAll(normKeys) ||
          normalization['camera_width'] != visual.imageWidth ||
          input == null ||
          !_sameArtifactJson(input.shape, [-1, visual.width]) ||
          !_sameArtifactJson(input.maxShape, [64, visual.width])) {
        throw const FormatException(
          'Visual camera/body/normalization ABI differs.',
        );
      }
    } else if (model.preprocessing.containsKey('visualProfile')) {
      throw const FormatException('Structured model carries a visual profile.');
    }
    if (normalization['schema_version'] != 1 ||
        normalization['mode'] != normalizationMode ||
        !_artifactDigest(normalization['source_hash']) ||
        mean.length != normalizationWidth ||
        scale.length != normalizationWidth ||
        mean.any((v) => v is! num || !v.isFinite) ||
        scale.any((v) => v is! num || !v.isFinite || v <= 0) ||
        model.preprocessing['normalization'] != normalization['mode'] ||
        model.preprocessing['sourceHash'] != normalization['source_hash'] ||
        recurrent['schema_version'] != 1 ||
        recurrent['reset'] != 'zero' ||
        recurrent['max_batch'] != 64 ||
        recurrent['dtype'] != 'float32' ||
        !_sameArtifactJson(recurrent['inputs'], {
          'hidden': [128],
          'cell': [128],
        }) ||
        !_sameArtifactJson(recurrent['outputs'], {
          'hidden': 'next_hidden',
          'cell': 'next_cell',
        }) ||
        !_sameArtifactJson(model.recurrent, {
          'hidden': 'next_hidden',
          'cell': 'next_cell',
        }) ||
        provenance['schema_version'] != 1 ||
        provenance['source_checkpoint_sha256'] !=
            data['source_checkpoint_sha256'] ||
        !_artifactDigest(provenance['training_config_hash']) ||
        !_artifactDigest(provenance['training_worker_sha256']) ||
        provenance['training_source_pins'] is! Map ||
        provenance['training_native_sha256'] is! Map ||
        provenance['license'] != 'LicenseRef-Repository-Authored' ||
        provenance['optimizer_exported'] != false ||
        provenance['critic_exported'] != false) {
      throw FormatException(
        'Model normalization/recurrent/provenance binding differs.',
      );
    }
    for (final key in ['hidden', 'cell']) {
      final spec = model.inputs.where((s) => s.name == key).firstOrNull;
      final output = model.outputs
          .where((s) => s.name == model.recurrent[key])
          .firstOrNull;
      if (spec == null ||
          output == null ||
          spec.dtype != MlDtype.float32 ||
          output.dtype != MlDtype.float32 ||
          !_sameArtifactJson(spec.shape, [-1, 128]) ||
          !_sameArtifactJson(output.shape, [-1, 128]) ||
          !_sameArtifactJson(spec.maxShape, [64, 128]) ||
          !_sameArtifactJson(output.maxShape, [64, 128])) {
        throw FormatException('Recurrent tensor shape differs.');
      }
    }
    final policy = data['policy'] as Map<String, dynamic>;
    if (policy.length != 7 ||
        policy['observation_input'] != 'observation' ||
        policy['continuous_output'] !=
            (controllerFamily == 'guard' ? null : 'action') ||
        policy['discrete_output'] !=
            (controllerFamily == 'guard' ? 'logits' : null) ||
        !_sameArtifactJson(policy['recurrent'], model.recurrent) ||
        policy['cadence_ticks'] != 1 ||
        policy['latency_ticks'] != 1 ||
        policy['max_hold_ticks'] != (visual?.maxHoldTicks ?? 0)) {
      throw FormatException('Policy timing/tensor pins differ.');
    }
    final contract = PolicyContract(
      model: model,
      observation: observation,
      decoder: decoder,
      encoder: visual == null
          ? const FramePolicyEncoder()
          : VisualPolicyEncoder(visual),
      continuousOutput: policy['continuous_output'] as String?,
      discreteOutput: policy['discrete_output'] as String?,
      observationInput: policy['observation_input'] as String,
      latencyTicks: 1,
      cadenceTicks: 1,
      maxHoldTicks: visual?.maxHoldTicks ?? 0,
    );
    final evaluation = ModelEvaluation.decode(
      files['evaluation.json']!,
      receiptHash: data['evaluation_report_hash'] as String,
      family: controllerFamily,
      modelHash: model.sha256,
      observationHash: observation.hash,
      actionHash: decoder.spec.hash,
    );
    if (![
      'python-onnxruntime-${model.runtimeVersion}-cpu',
      'native-onnxruntime-${model.runtimeVersion}-cpu',
    ].contains(evaluation.provider)) {
      throw FormatException(
        'Accepted artifact requires an exact ONNX provider.',
      );
    }
    final registeredPlans = visual == null
        ? structuredModelEvaluationPlanHashes
        : visualModelEvaluationPlanHashes[visual.mode]!;
    if (!registeredPlans.contains(evaluation.planHash) ||
        visual != null && evaluation.fixedHz != visual.fixedHz) {
      throw FormatException(
        'Model evaluation plan or visual simulation rate is not registered.',
      );
    }
    if (!evaluation.accepted ||
        evaluation.planHash != data['evaluation_plan_hash']) {
      throw FormatException('Model has no exact accepted evaluation.');
    }
    _validateNativeParity(provenance, model.sha256);
    if (data['precision'] == 'int8') {
      _validateQuantization(
        data,
        provenance,
        utf8.decode(files['provenance.json']!),
        evaluation,
      );
    } else if (provenance.containsKey('quantization')) {
      throw FormatException('Float artifact carries quantization proof.');
    }
    return ModelArtifact._(
      data['id'] as String,
      family,
      data['source_checkpoint_sha256'] as String,
      data['precision'] as String,
      contract,
      evaluation,
      manifest,
      files,
    );
  }
}

bool _sameArtifactJson(Object? left, Object? right) {
  Object? sorted(Object? value) {
    if (value is List) return value.map(sorted).toList();
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final key in keys) key: sorted(value[key])};
    }
    return value;
  }

  return jsonEncode(sorted(left)) == jsonEncode(sorted(right));
}

void _validateArtifactEnvelope(Map<String, dynamic> data) {
  const keys = {
    'schema_version',
    'id',
    'family',
    'model_sha256',
    'source_checkpoint_sha256',
    'observation_schema_hash',
    'action_schema_hash',
    'controller_mapping',
    'evaluation_report_hash',
    'evaluation_plan_hash',
    'files',
    'policy',
    'precision',
    'provider',
    'accepted',
  };
  if (data.keys.toSet().difference(keys).isNotEmpty ||
      data.length != keys.length ||
      data['schema_version'] != 1 ||
      data['accepted'] != true ||
      data['provider'] != 'cpu' ||
      data['family'] is! String ||
      !RegExp(
        r'^(guard|vehicle)(-visual-(rgb|depth|combined))?$',
      ).hasMatch(data['family']) ||
      !['float32', 'float16', 'int8'].contains(data['precision']) ||
      data['id'] is! String ||
      !RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(data['id']) ||
      ![
        'model_sha256',
        'source_checkpoint_sha256',
        'observation_schema_hash',
        'action_schema_hash',
        'evaluation_report_hash',
        'evaluation_plan_hash',
      ].every((k) => _artifactDigest(data[k]))) {
    throw FormatException('Invalid accepted model artifact envelope.');
  }
}

void _validateNativeParity(Map<String, dynamic> provenance, String modelHash) {
  final p = provenance['native_parity'];
  if (p is! Map ||
      p['schema_version'] != 1 ||
      p['model_sha256'] != modelHash ||
      p['status'] != 'passed' ||
      p['provider'] != 'native-onnxruntime-1.23.2-cpu' ||
      p['steps'] is! int ||
      p['steps'] < 1000 ||
      p['steps'] > 1000000 ||
      p['completed_runs'] != p['steps'] ||
      p['typed_controller_steps'] != p['steps'] ||
      p['live_sessions'] != 0 ||
      p['live_results'] != 0 ||
      p['atol'] != 1e-5 ||
      p['rtol'] != 1e-4 ||
      !_artifactDigest(p['native_worker_sha256']) ||
      !_artifactDigest(p['input_sequence_hash']) ||
      p['max_absolute_error'] is! num ||
      !(p['max_absolute_error'] as num).isFinite ||
      p['max_absolute_error'] < 0 ||
      p['native_asset_sha256'] is! Map ||
      (p['native_asset_sha256'] as Map).isEmpty ||
      (p['native_asset_sha256'] as Map).length > 32 ||
      !(p['native_asset_sha256'] as Map).values.every(_artifactDigest)) {
    throw FormatException('Accepted artifact native parity proof differs.');
  }
}

void _validateQuantization(
  Map<String, dynamic> data,
  Map<String, dynamic> provenance,
  String rawProvenance,
  ModelEvaluation candidate,
) {
  final q = provenance['quantization'];
  const keys = {
    'precision',
    'format',
    'operators',
    'baseline_bundle_hash',
    'baseline_model_sha256',
    'calibration_partition',
    'calibration_steps',
    'calibration_manifest_hashes',
    'calibration_sequence_hash',
    'baseline_bundle_manifest',
    'baseline_report',
    'baseline_report_hash',
    'candidate_report_hash',
    'success_loss',
  };
  if (q is! Map ||
      q.length != keys.length ||
      !q.keys.toSet().containsAll(keys) ||
      q['precision'] != 'int8' ||
      q['format'] != 'QDQ' ||
      !_sameArtifactJson(q['operators'], ['MatMul', 'Gemm']) ||
      q['calibration_partition'] != 'train' ||
      q['calibration_steps'] is! int ||
      q['calibration_steps'] < 1 ||
      q['calibration_steps'] > 2000 ||
      !_artifactDigest(q['calibration_sequence_hash']) ||
      q['calibration_manifest_hashes'] is! List ||
      (q['calibration_manifest_hashes'] as List).isEmpty ||
      (q['calibration_manifest_hashes'] as List).length > 256 ||
      !(q['calibration_manifest_hashes'] as List).every(_artifactDigest)) {
    throw FormatException('Quantization calibration proof differs.');
  }
  final calibration = (q['calibration_manifest_hashes'] as List).toSet();
  final sourcePins = provenance['training_source_pins']['train'];
  final parityPins = provenance['native_parity']['source_manifest_hashes'];
  if (calibration.length != (q['calibration_manifest_hashes'] as List).length ||
      sourcePins is! List ||
      sourcePins.isEmpty ||
      sourcePins.length > 256 ||
      !sourcePins.every(_artifactDigest) ||
      !calibration.containsAll(sourcePins) ||
      parityPins is! List ||
      parityPins.length != calibration.length ||
      parityPins.toSet().length != calibration.length ||
      !parityPins.toSet().containsAll(calibration)) {
    throw FormatException('Quantization calibration source pins differ.');
  }
  // Preserve embedded Python float spellings instead of re-encoding their plan.
  final rawProof = _rawJsonField(rawProvenance, 'quantization');
  final baselineBytes = Uint8List.fromList(
    utf8.encode(_rawJsonField(rawProof, 'baseline_bundle_manifest')),
  );
  final reportBytes = Uint8List.fromList(
    utf8.encode(_rawJsonField(rawProof, 'baseline_report')),
  );
  if (baselineBytes.length > 65536 ||
      reportBytes.length > 262144 ||
      !_artifactDigest(q['baseline_bundle_hash']) ||
      !_artifactDigest(q['baseline_model_sha256']) ||
      !_artifactDigest(q['baseline_report_hash']) ||
      sha256.convert(baselineBytes).toString() != q['baseline_bundle_hash']) {
    throw FormatException('Quantization baseline byte/hash proof differs.');
  }
  final baseline =
      jsonDecode(utf8.decode(baselineBytes)) as Map<String, dynamic>;
  _validateArtifactEnvelope(baseline);
  if (baseline['precision'] != 'float32' ||
      baseline['family'] != data['family'] ||
      baseline['model_sha256'] != q['baseline_model_sha256'] ||
      baseline['model_sha256'] == data['model_sha256'] ||
      baseline['evaluation_report_hash'] != q['baseline_report_hash'] ||
      q['candidate_report_hash'] != candidate.receiptHash ||
      [
        'source_checkpoint_sha256',
        'observation_schema_hash',
        'action_schema_hash',
        'controller_mapping',
        'evaluation_plan_hash',
        'policy',
        'provider',
      ].any((k) => !_sameArtifactJson(baseline[k], data[k]))) {
    throw FormatException('Quantization baseline identity differs.');
  }
  Map<String, Map> rows(Map envelope) {
    final values = envelope['files'];
    if (values is! List || values.length != ModelArtifact.fileNames.length) {
      throw FormatException('Quantization baseline resource manifest differs.');
    }
    final result = <String, Map>{};
    var total = 0;
    for (final row in values) {
      if (row is! Map ||
          row.length != 3 ||
          !ModelArtifact.fileNames.contains(row['path']) ||
          result.containsKey(row['path']) ||
          !_artifactDigest(row['sha256']) ||
          row['bytes'] is! int ||
          row['bytes'] < 1 ||
          row['bytes'] >
              (row['path'] == 'actor.onnx'
                  ? 8388608
                  : row['path'] == 'evaluation.json'
                  ? 16777216
                  : 1048576)) {
        throw FormatException('Quantization baseline resource pin differs.');
      }
      total += row['bytes'] as int;
      result[row['path'] as String] = row;
    }
    if (total > 33554432) {
      throw FormatException('Quantization baseline budget differs.');
    }
    return result;
  }

  final baselineRows = rows(baseline), candidateRows = rows(data);
  final evaluationRow = baselineRows['evaluation.json']!;
  if (evaluationRow['sha256'] != q['baseline_report_hash'] ||
      evaluationRow['bytes'] != reportBytes.length ||
      baselineRows['actor.onnx']!['sha256'] != baseline['model_sha256'] ||
      [
        'observation.json',
        'action.json',
        'normalization.json',
        'recurrent.json',
      ].any((k) => !_sameArtifactJson(baselineRows[k], candidateRows[k]))) {
    throw FormatException(
      'Quantization baseline resource/evaluation proof differs.',
    );
  }
  final previous = ModelEvaluation.decode(
    reportBytes,
    receiptHash: q['baseline_report_hash'] as String,
    family: data['family'] as String,
    modelHash: q['baseline_model_sha256'] as String,
    observationHash: data['observation_schema_hash'] as String,
    actionHash: data['action_schema_hash'] as String,
  );
  if (!previous.accepted ||
      previous.provider != candidate.provider ||
      previous.planHash != candidate.planHash ||
      previous.fixedHz != candidate.fixedHz ||
      !structuredModelEvaluationPlanHashes.contains(previous.planHash)) {
    throw FormatException('Quantization baseline evaluation differs.');
  }
  final loss = previous.successRate - candidate.successRate;
  if (q['success_loss'] is! num ||
      !(q['success_loss'] as num).isFinite ||
      ((q['success_loss'] as num).toDouble() - loss).abs() > 1e-12 ||
      loss > .020000000001) {
    throw FormatException(
      'Quantization success loss exceeds or differs from two percentage points.',
    );
  }
}
