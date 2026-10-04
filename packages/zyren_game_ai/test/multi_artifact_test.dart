import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_game_ai/artifact.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'artifact_test.dart' as codec;

// Synthetic receipt data tests the codec. It never qualifies or runs a model.
Object? canonical(Object? value) => value is Map
    ? {
        for (final key in (value.keys.cast<String>().toList()..sort()))
          key: canonical(value[key]),
      }
    : value is List
    ? value.map(canonical).toList()
    : value;
Uint8List encoded(Object? value) =>
    Uint8List.fromList(utf8.encode(jsonEncode(canonical(value))));
String hash(Object? value) => sha256.convert(encoded(value)).toString();

Map<String, Object?> aggregate(List<Map<String, Object?>> rows) {
  final count = rows.length;
  int sum(String key) => rows.fold(0, (v, r) => v + (r[key] as int));
  int matching(String key, Object value) =>
      rows.where((r) => r[key] == value).length;
  final wins = matching('result', 'win'),
      contacts = matching('collision', true);
  (double, double) ci(int n) {
    const z = 1.959963984540054;
    final p = n / count, d = 1 + z * z / count;
    final center = (p + z * z / (2 * count)) / d;
    final radius =
        z * math.sqrt(p * (1 - p) / count + z * z / (4 * count * count)) / d;
    return (
      n == 0 ? 0.0 : math.max(0, center - radius),
      n == count ? 1.0 : math.min(1, center + radius),
    );
  }

  final win = ci(wins), contact = ci(contacts);
  return {
    'requested': count,
    'completed': matching('status', 'completed'),
    'failed': matching('status', 'failed'),
    'cancelled': matching('status', 'cancelled'),
    'successes': wins,
    'success_denominator': count,
    'success_rate': wins / count,
    'success_lower95': win.$1,
    'success_upper95': win.$2,
    'collisions': contacts,
    'collision_denominator': count,
    'collision_rate': contacts / count,
    'collision_lower95': contact.$1,
    'collision_upper95': contact.$2,
    'reward_sum': 0.0,
    'progress_sum': 0.0,
    'invalid_actions': sum('invalid_actions'),
    'fallback_steps': sum('fallback_steps'),
    'wins': wins,
    'draws': matching('result', 'draw'),
    'losses': matching('result', 'loss'),
    'win_denominator': count,
    'win_rate': wins / count,
    'win_lower95': win.$1,
    'win_upper95': win.$2,
  };
}

Map<String, dynamic> receiptFixture({bool historicalContact = false}) {
  const families = ['cooperative-search', 'competitive-pursuit'];
  final profiles = {
    for (final family in families)
      family: TrainingMultiProfiles.forTask(task: family),
  };
  Map<String, Object?> scenario(String family, [String variant = 'test']) => {
    'schema_version': 1,
    'id': '$family-$variant',
    'partition': 'test',
    'game_build_hash': 'build',
    'observation_schema_hash': profiles[family]!.spec.hash,
    'action_schema_hash': profiles[family]!.decoder.spec.hash,
    'callback_id': family,
    'reward_terms': [
      {'id': 'progress', 'cap': 1.0},
    ],
    'seed': 7,
    'max_steps': 600,
    'control_cadence': 1,
    'latency_ticks': 1,
    'assets': <Object>[],
    'settings': {'map': variant, 'fixed_hz': 50},
  };
  final opponents = [
    for (final kind in ['fixed', 'withheld', 'historical'])
      for (var i = 0; i < (kind == 'historical' ? 4 : 2); i++)
        {
          'id': '$kind-$i',
          'kind': kind,
          'policy_hash': hash([kind, i]),
          'config_hash': hash(['config', kind, i]),
        },
  ];
  final cases = <Map<String, Object?>>[
    {
      'id': 'joint',
      'family': families[0],
      'role': 'joint',
      'opponent': null,
      'phase': 'heldout',
      'scenario': scenario(families[0]),
      'seeds': List.generate(200, (i) => 100 + i),
      'stress': {'miss_every': 0, 'delay_every': 0},
      'coverage': ['joint-goal'],
    },
    for (final role in ['pursuer', 'evader'])
      for (final opponent in opponents)
        {
          'id': '$role-${opponent['id']}',
          'family': families[1],
          'role': role,
          'opponent': opponent['id'],
          'phase': opponent['kind'] == 'historical' ? 'historical' : 'heldout',
          'scenario': scenario(families[1]),
          'seeds': List.generate(50, (i) => 300 + i),
          'stress': {'miss_every': 0, 'delay_every': 0},
          'coverage': ['role-cross-play'],
        },
  ];
  final plan = {
    'schema_version': 2,
    'id': 'synthetic-team-codec',
    'targets': multiModelEvaluationTargets,
    'cases': cases,
    'training_scenario_hashes': <String>[],
    'training_opponent_hashes': <String>[],
    'worker_sha256': 'a' * 64,
    'worker_native_sha256': {'lib/physics.dylib': 'b' * 64},
    'multi_profiles': {
      for (final p in profiles.entries) p.key: p.value.toJson(),
    },
    'multi_profile_hashes': {
      for (final p in profiles.entries) p.key: p.value.configurationHash,
    },
    'opponents': opponents,
    'initial_baseline': true,
    'previous_checkpoint': null,
    'paired_worlds': [
      for (final f in families)
        {
          'family': f,
          'left': scenario(f, 'left'),
          'right': scenario(f, 'right'),
          'seed': 7,
          'steps': 20,
          'actors': ['a'],
        },
    ],
  };
  final rows = <Map<String, Object?>>[];
  for (final c in cases) {
    for (final seed in c['seeds'] as List) {
      rows.add({
        'index': rows.length,
        'seed': seed,
        'scenario': (c['scenario'] as Map)['id'],
        'family': c['family'],
        'status': 'completed',
        'success': true,
        'collision': historicalContact && rows.length == 800,
        'reward': 0.0,
        'progress': 0.0,
        'steps': 100,
        'invalid_actions': 0,
        'fallback_steps': 0,
        'error': null,
        'role': c['role'],
        'result': 'win',
        'opponent': c['opponent'],
      });
    }
  }
  final roleMetrics = <String, Object?>{},
      opponentMetrics = <String, Object?>{},
      historyMetrics = <String, Object?>{},
      historyRoles = <String, Object?>{};
  for (final role in ['pursuer', 'evader']) {
    final selected = rows.where((r) => r['role'] == role).toList();
    bool historical(Map r) =>
        (r['opponent'] as String).startsWith('historical');
    roleMetrics[role] = aggregate(
      selected.where((r) => !historical(r)).toList(),
    );
    historyRoles[role] = aggregate(selected.where(historical).toList());
    opponentMetrics[role] = {
      for (final o in opponents.where((o) => o['kind'] != 'historical'))
        o['id']!: aggregate(
          selected.where((r) => r['opponent'] == o['id']).toList(),
        ),
    };
    historyMetrics[role] = {
      for (final o in opponents.where((o) => o['kind'] == 'historical'))
        o['id']!: aggregate(
          selected.where((r) => r['opponent'] == o['id']).toList(),
        ),
    };
  }
  final models = {
    'cooperative-search': 'c' * 64,
    'competitive-pursuit': 'd' * 64,
  };
  return jsonDecode(
        jsonEncode({
          'schema_version': 2,
          'plan': plan,
          'plan_hash': hash(plan),
          'model_hash': hash(models),
          'family_model_hashes': models,
          'role_model_hashes': {
            'pursuer': models[families[1]],
            'evader': models[families[1]],
          },
          'provider': 'test-identity-only',
          'status': historicalContact ? 'failed' : 'passed',
          'reasons': historicalContact
              ? ['evader historical contact target missed']
              : <String>[],
          'requested': rows.length,
          'metrics': {
            'cooperative-search': aggregate(
              rows.where((r) => r['role'] == 'joint').toList(),
            ),
            'competitive-pursuit': roleMetrics,
          },
          'episodes': rows,
          'opponent_metrics': opponentMetrics,
          'historical_metrics': historyMetrics,
          'historical_role_metrics': historyRoles,
          'layout_seed_counts': {
            'cooperative-search': 200,
            'competitive-pursuit': {'pursuer': 50, 'evader': 50},
          },
          'hidden_state_leaks': 0,
          'reward_exploits': 0,
          'stale_outputs': 0,
          'worker_failures': 0,
          'worker_exit_codes': [0],
          'worker_sha256': plan['worker_sha256'],
          'worker_native_sha256': plan['worker_native_sha256'],
        }),
      )
      as Map<String, dynamic>;
}

ModelEvaluation decode(
  Map<String, dynamic> value, {
  String family = 'competitive-pursuit',
}) {
  final bytes = encoded(value),
      profile = TrainingMultiProfiles.forTask(task: family);
  return ModelEvaluation.decode(
    bytes,
    receiptHash: sha256.convert(bytes).toString(),
    family: family,
    modelHash: value['family_model_hashes'][family] as String,
    observationHash: profile.spec.hash,
    actionHash: profile.decoder.spec.hash,
  );
}

Map<String, dynamic> insufficientHeldoutFixture() {
  final value = receiptFixture(), plan = value['plan'] as Map;
  final cases = <Map<String, dynamic>>[], rows = <Map<String, dynamic>>[];
  for (final old in plan['cases'] as List) {
    final scenario = old['scenario'] as Map;
    final split =
        old['family'] == 'competitive-pursuit' && old['phase'] == 'heldout';
    final template = (value['episodes'] as List).cast<Map>().firstWhere(
      (r) =>
          r['scenario'] == scenario['id'] &&
          r['role'] == old['role'] &&
          r['opponent'] == old['opponent'],
    );
    for (var block = 0; block < (split ? 5 : 1); block++) {
      final c = jsonDecode(jsonEncode(old)) as Map<String, dynamic>;
      if (split) {
        c['id'] = '${c['id']}_$block';
        c['scenario']['id'] = '${scenario['id']}_$block';
        c['scenario']['settings']['block'] = block;
        c['seeds'] = (old['seeds'] as List).take(10).toList();
      }
      cases.add(c);
      for (final seed in c['seeds'] as List) {
        rows.add({
          ...template.cast<String, dynamic>(),
          'index': rows.length,
          'seed': seed,
          'scenario': c['scenario']['id'],
        });
      }
    }
  }
  plan['cases'] = cases;
  value['episodes'] = rows;
  value['plan_hash'] = hash(plan);
  value['layout_seed_counts']['competitive-pursuit'] = {
    'pursuer': 10,
    'evader': 10,
  };
  value['status'] = 'failed';
  value['reasons'] = ['held-out layout seeds too few'];
  return value;
}

void main() {
  test('renaming one historical model cannot satisfy checkpoint diversity', () {
    final value = receiptFixture();
    final opponents = value['plan']['opponents'] as List;
    opponents[4]['policy_hash'] = opponents[5]['policy_hash'];
    value['plan_hash'] = hash(value['plan']);
    expect(
      () => decode(value),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'diversity',
          contains('distinct immutable policy bytes'),
        ),
      ),
    );
  });
  test('historical seeds cannot repair insufficient held-out layouts', () {
    final value = insufficientHeldoutFixture();
    expect(decode(value).accepted, isFalse);
    value['layout_seed_counts']['competitive-pursuit'] = {
      'pursuer': 50,
      'evader': 50,
    };
    value['status'] = 'passed';
    value['reasons'] = <String>[];
    expect(() => decode(value), throwsFormatException);
  });
  test(
    'historical contacts fail their own role gate without combining held-out slots',
    () {
      final value = receiptFixture(historicalContact: true);
      expect(decode(value).accepted, isFalse);
      expect(
        value['metrics']['competitive-pursuit']['evader']['collisions'],
        0,
      );
      expect(
        value['historical_role_metrics']['evader']['collision_upper95'],
        greaterThan(.02),
      );
      value['status'] = 'passed';
      value['reasons'] = <String>[];
      expect(() => decode(value), throwsFormatException);
    },
  );
  test(
    'synthetic multi bundle cannot activate through the empty plan registry',
    () {
      const task = 'competitive-pursuit';
      final f = codec.CodecFixture(),
          profile = TrainingMultiProfiles.forTask(task: task);
      final old = MlModelManifest.decode(utf8.decode(f.files['model.json']!));
      final norm =
          jsonDecode(utf8.decode(f.files['normalization.json']!)) as Map;
      final model = MlModelManifest(
        id: old.id,
        modelFile: old.modelFile,
        sha256: old.sha256,
        opset: old.opset,
        inputs: [
          MlTensorSpec(
            name: 'observation',
            dtype: MlDtype.float32,
            shape: [-1, profile.spec.width],
            maxShape: [64, profile.spec.width],
          ),
          ...old.inputs.where((s) => s.name != 'observation'),
        ],
        outputs: old.outputs,
        recurrent: old.recurrent,
        preprocessing: {...old.preprocessing, 'multiProfile': profile.toJson()},
      );
      final report = receiptFixture();
      report['provider'] = 'python-onnxruntime-1.23.2-cpu';
      report['family_model_hashes'][task] = old.sha256;
      report['role_model_hashes'] = {
        'pursuer': old.sha256,
        'evader': old.sha256,
      };
      report['model_hash'] = hash(report['family_model_hashes']);
      f.files['model.json'] = Uint8List.fromList(utf8.encode(model.encode()));
      f.files['observation.json'] = codec.jsonBytes(profile.spec.toJson());
      f.files['normalization.json'] = codec.jsonBytes({
        ...norm,
        'mean': List.filled(profile.spec.width, 0.0),
        'scale': List.filled(profile.spec.width, 1.0),
      });
      f.files['evaluation.json'] = encoded(report);
      f.bundle.addAll({
        'family': task,
        'observation_schema_hash': profile.spec.hash,
        'evaluation_report_hash': sha256
            .convert(f.files['evaluation.json']!)
            .toString(),
        'evaluation_plan_hash': report['plan_hash'],
      });
      (f.bundle['policy'] as Map)['max_hold_ticks'] = 2;
      expect(
        () => ModelArtifact.decode(f.manifest, f.files),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'gate',
            contains('not registered'),
          ),
        ),
      );
      f.bundle['precision'] = 'int8';
      expect(
        () => ModelArtifact.decode(f.manifest, f.files),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'gate',
            contains('precision qualification'),
          ),
        ),
      );
    },
  );
  test('v2 codec keeps joint and held-out role results separate', () {
    final value = receiptFixture(), report = decode(value);
    expect(report.accepted, isTrue);
    expect(report.fixedHz, 50);
    expect(report.schemaVersion, 2);
    expect(report.roleMetrics.keys, {'pursuer', 'evader'});
    expect(report.roleMetrics['pursuer']!['requested'], 200);
    expect(
      () => report.roleMetrics['pursuer']!['requested'] = 0,
      throwsUnsupportedError,
    );
    expect(decode(value, family: 'cooperative-search').successRate, 1);
    expect(
      multiModelEvaluationPlanHashes.values.every((v) => v.isEmpty),
      isTrue,
    );
  });
  test(
    'v2 rehashed receipt rejects omitted history and altered role aggregates',
    () {
      for (final mutate in <void Function(Map<String, dynamic>)>[
        (v) => v['episodes'].removeLast(),
        (v) => v['historical_role_metrics']['evader']['collisions'] = 1,
        (v) => v['metrics']['competitive-pursuit']['evader']['wins'] = 201,
        (v) => v['role_model_hashes']['evader'] = 'e' * 64,
        (v) => v['hidden_state_leaks'] = 1,
        (v) => v['worker_exit_codes'] = <int>[],
        (v) => v['episodes'][200]['role'] = 'evader',
      ]) {
        final value = receiptFixture();
        mutate(value);
        expect(() => decode(value), throwsFormatException);
      }
    },
  );
  test('v2 rejects independently rehashed changed plan gates and clock pins', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (v) => v['plan']['targets']['competitive-pursuit']['win_rate'] = .1,
      (v) => v['plan']['cases'][0]['scenario']['settings']['fixed_hz'] = 60,
      (v) => v['plan']['paired_worlds'].removeLast(),
      (v) => v['plan']['opponents'][2]['policy_hash'] =
          v['plan']['opponents'][3]['policy_hash'],
      (v) =>
          v['plan']['multi_profiles']['cooperative-search']['message_cadence_ticks'] =
              1,
    ]) {
      final value = receiptFixture();
      mutate(value);
      value['plan_hash'] = hash(value['plan']);
      expect(() => decode(value), throwsFormatException);
    }
  });
}
