import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game_ai/artifact.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'artifact_test.dart' show CodecFixture, digest;

Object? sortedJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: sortedJson(value[key])};
  }
  if (value is List) return value.map(sortedJson).toList();
  return value;
}

Uint8List canonical(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(sortedJson(value))));

Map<String, dynamic> repairedReport(CodecFixture fixture) {
  final report =
      jsonDecode(utf8.decode(fixture.files['evaluation.json']!))
          as Map<String, dynamic>;
  final plan = report['plan'] as Map<String, dynamic>;
  plan['id'] = 'collision-repair-codec-test';
  plan['worker_sha256'] = 'a' * 64;
  plan['worker_native_sha256']['lib/libzyren_physics.dylib'] = 'b' * 64;
  plan['revision'] = {
    'supersedes':
        'deaf8017551bc1709af5f6e689f4c3f377f52b2822c6a02c9522986cb52e3afd',
    'reason': 'collision-only island and joint bookkeeping repair',
    'case_content_hash':
        'b5a7eff352c517411b818b741e82c0a75bf330f254f78764fe2e43f307872f47',
  };
  return report;
}

void repinReport(Map<String, dynamic> report) {
  report['plan_hash'] = digest(canonical(report['plan']));
  report['worker_sha256'] = report['plan']['worker_sha256'];
  report['worker_native_sha256'] = report['plan']['worker_native_sha256'];
}

ModelEvaluation decode(Map<String, dynamic> report, CodecFixture fixture) {
  repinReport(report);
  final bytes = canonical(report);
  return ModelEvaluation.decode(
    bytes,
    receiptHash: digest(bytes),
    family: 'guard',
    modelHash: fixture.bundle['model_sha256']! as String,
    observationHash: TrainingProfiles.guard().spec.hash,
    actionHash: TrainingActions.character.hash,
  );
}

void main() {
  test(
    'collision revision parses exact old suite but cannot activate an unregistered plan',
    () {
      final fixture = CodecFixture(), report = repairedReport(CodecFixture());
      final parsed = decode(report, fixture);
      expect(parsed.accepted, isTrue);
      expect(
        structuredModelEvaluationPlanHashes,
        isNot(contains(report['plan_hash'])),
      );
      fixture.files['evaluation.json'] = canonical(report);
      fixture.bundle['evaluation_report_hash'] = digest(
        fixture.files['evaluation.json']!,
      );
      fixture.bundle['evaluation_plan_hash'] = report['plan_hash'];
      expect(
        () => ModelArtifact.decode(fixture.manifest, fixture.files),
        throwsFormatException,
      );
    },
  );
  test('collision revision rejects content rehash and foreign lineage', () {
    for (final mutation in ['seed', 'pair', 'training', 'lineage', 'reason']) {
      final fixture = CodecFixture(), report = repairedReport(CodecFixture());
      final plan = report['plan'];
      if (mutation == 'seed') {
        plan['cases'][0]['seeds'][0]++;
      }
      if (mutation == 'pair') {
        plan['paired_worlds']['seed']++;
      }
      if (mutation == 'training') {
        plan['training_scenario_hashes'].add('c' * 64);
      }
      if (mutation == 'lineage') {
        plan['revision']['supersedes'] = 'd' * 64;
      }
      if (mutation == 'reason') {
        plan['revision']['reason'] = 'new physics';
      }
      plan['revision']['case_content_hash'] = digest(
        canonical({
          for (final key in [
            'cases',
            'paired_worlds',
            'targets',
            'training_scenario_hashes',
          ])
            key: plan[key],
        }),
      );
      expect(
        () => decode(report, fixture),
        throwsFormatException,
        reason: mutation,
      );
    }
  });
}
