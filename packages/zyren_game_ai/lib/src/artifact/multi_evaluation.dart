part of '../../artifact.dart';

/// Numeric v2 gates. These do not register or qualify an evaluation plan.
const multiModelEvaluationTargets = {
  'cooperative-search': {
    'joint_episodes': 200,
    'joint_success_rate': .95,
    'joint_success_lower95': .90,
    'collision_upper95': .02,
  },
  'competitive-pursuit': {
    'episodes_per_role': 200,
    'opponents_per_role': 4,
    'episodes_per_opponent': 50,
    'win_rate': .60,
    'win_lower95': .50,
    'per_opponent_win_rate': .50,
    'collision_upper95': .02,
    'historical_opponents_min': 4,
    'historical_episodes_per_role': 200,
    'historical_episodes_per_opponent': 50,
    'historical_win_rate': .40,
    'maximum_cycling_drop': .10,
  },
};

/// No multi-agent evaluation plans have been locked for artifact acceptance.
const multiModelEvaluationPlanHashes = <String, Set<String>>{
  'cooperative-search': {},
  'competitive-pursuit': {},
};

Never _multiInvalid(String reason) => throw FormatException(reason);
Map<String, dynamic> _multiMap(Object? value, [Set<String>? keys]) {
  if (value is! Map<String, dynamic> ||
      keys != null &&
          (value.length != keys.length ||
              !value.keys.toSet().containsAll(keys))) {
    _multiInvalid('Multi receipt object fields differ.');
  }
  return value;
}

List<dynamic> _multiList(Object? value, int minimum, int maximum) {
  if (value is! List || value.length < minimum || value.length > maximum) {
    _multiInvalid('Multi receipt list budget differs.');
  }
  return value;
}

bool _multiInt(Object? n, [int minimum = 0, int maximum = 10000000]) =>
    n is int && n >= minimum && n <= maximum;
bool _multiNumber(Object? n) => n is num && n.isFinite;
bool _multiId(Object? n, [int maximum = 256]) =>
    n is String &&
    n.length <= maximum &&
    RegExp(r'^[A-Za-z0-9_.:/-]+$').hasMatch(n);
bool _multiCatalogId(Object? n) =>
    n is String && RegExp(r'^[A-Za-z0-9_-]{1,80}$').hasMatch(n);

Map<String, dynamic> _multiJson(String raw) {
  var depth = 0, quoted = false, escaped = false;
  for (final c in raw.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == 92) {
        escaped = true;
      } else if (c == 34) {
        quoted = false;
      }
    } else if (c == 34) {
      quoted = true;
    } else if (c == 91 || c == 123) {
      if (++depth > 32) _multiInvalid('Multi metadata depth exceeds budget.');
    } else if (c == 93 || c == 125) {
      depth--;
    }
  }
  final value = jsonDecode(raw), pending = <Object?>[value];
  var nodes = 0;
  while (pending.isNotEmpty) {
    if (++nodes > 100000) _multiInvalid('Multi metadata nodes exceed budget.');
    final v = pending.removeLast();
    if (v is Map) {
      pending.addAll(v.values);
    } else if (v is List) {
      pending.addAll(v);
    }
  }
  return _multiMap(value);
}

String _multiHash(Object? value) {
  Object? sorted(Object? v) => v is Map
      ? {
          for (final key in (v.keys.cast<String>().toList()..sort()))
            key: sorted(v[key]),
        }
      : v is List
      ? v.map(sorted).toList()
      : v;
  return sha256.convert(utf8.encode(jsonEncode(sorted(value)))).toString();
}

Map<String, dynamic> _multiScenario(
  Object? value,
  TrainingMultiProfile profile,
  List<dynamic> training,
) {
  final s = _multiMap(value, {
    'schema_version',
    'id',
    'partition',
    'game_build_hash',
    'observation_schema_hash',
    'action_schema_hash',
    'callback_id',
    'reward_terms',
    'seed',
    'max_steps',
    'control_cadence',
    'latency_ticks',
    'assets',
    'settings',
  });
  if (s['schema_version'] != 1 ||
      s['partition'] != 'test' ||
      !['id', 'game_build_hash', 'callback_id'].every((k) => _multiId(s[k])) ||
      s['observation_schema_hash'] != profile.spec.hash ||
      s['action_schema_hash'] != profile.decoder.spec.hash ||
      !_multiInt(s['seed'], 0, 9007199254740991) ||
      !_multiInt(s['max_steps'], 1) ||
      s['control_cadence'] != 1 ||
      s['latency_ticks'] != 1 ||
      _multiMap(s['settings'])['fixed_hz'] != profile.fixedHz) {
    _multiInvalid('Multi held-out scenario/controller ABI differs.');
  }
  final terms = _multiList(s['reward_terms'], 1, 64), seen = <String>{};
  for (final v in terms) {
    final t = _multiMap(v, {'id', 'cap'});
    if (!_multiId(t['id']) ||
        !seen.add(t['id'] as String) ||
        !_multiNumber(t['cap']) ||
        t['cap'] <= 0 ||
        t['cap'] > 1000) {
      _multiInvalid('Multi reward term differs.');
    }
  }
  for (final v in _multiList(s['assets'], 0, 256)) {
    final a = _multiMap(v, {'id', 'source', 'license', 'hash'});
    if (!a.values.every(_multiId)) {
      _multiInvalid('Multi asset provenance differs.');
    }
  }
  final content = {...s}
    ..remove('id')
    ..remove('partition')
    ..remove('seed');
  if (utf8.encode(jsonEncode(s)).length > 65536 ||
      training.contains(_multiHash(content))) {
    _multiInvalid('Multi scenario budget or TRAIN/test separation differs.');
  }
  return s;
}

ModelEvaluation _decodeMultiEvaluation(
  Uint8List bytes, {
  required String receiptHash,
  required String family,
  required String modelHash,
  required String observationHash,
  required String actionHash,
}) {
  if (bytes.length > 16777216 ||
      ![
        receiptHash,
        modelHash,
        observationHash,
        actionHash,
      ].every(_artifactDigest) ||
      sha256.convert(bytes).toString() != receiptHash) {
    _multiInvalid('Multi evaluation receipt size or pins differ.');
  }
  final raw = utf8.decode(bytes),
      data = _multiMap(_multiJson(raw), {
        'schema_version',
        'plan',
        'plan_hash',
        'model_hash',
        'family_model_hashes',
        'provider',
        'status',
        'reasons',
        'requested',
        'metrics',
        'episodes',
        'opponent_metrics',
        'historical_metrics',
        'role_model_hashes',
        'layout_seed_counts',
        'hidden_state_leaks',
        'reward_exploits',
        'stale_outputs',
        'worker_failures',
        'worker_exit_codes',
        'worker_sha256',
        'worker_native_sha256',
        'historical_role_metrics',
      });
  final p = _multiMap(data['plan'], {
    'schema_version',
    'id',
    'cases',
    'paired_worlds',
    'targets',
    'training_scenario_hashes',
    'training_opponent_hashes',
    'worker_sha256',
    'worker_native_sha256',
    'multi_profiles',
    'multi_profile_hashes',
    'opponents',
    'initial_baseline',
    'previous_checkpoint',
  });
  if (data['schema_version'] != 2 ||
      p['schema_version'] != 2 ||
      p['id'] is! String ||
      (p['id'] as String).isEmpty ||
      (p['id'] as String).length > 128 ||
      !['passed', 'failed'].contains(data['status']) ||
      !_artifactDigest(data['plan_hash']) ||
      sha256.convert(utf8.encode(_rawJsonField(raw, 'plan'))).toString() !=
          data['plan_hash'] ||
      !_sameArtifactJson(p['targets'], multiModelEvaluationTargets) ||
      data['provider'] is! String ||
      (data['provider'] as String).isEmpty ||
      !_artifactDigest(p['worker_sha256']) ||
      data['worker_sha256'] != p['worker_sha256'] ||
      !_sameArtifactJson(
        data['worker_native_sha256'],
        p['worker_native_sha256'],
      )) {
    _multiInvalid('Multi evaluation plan/worker/gates differ.');
  }
  final native = _multiMap(p['worker_native_sha256']);
  if (native.isEmpty ||
      native.length > 64 ||
      native.entries.any(
        (e) =>
            !e.key.startsWith('lib/') ||
            e.key.split('/').contains('..') ||
            e.key.contains('\\') ||
            !_artifactDigest(e.value),
      )) {
    _multiInvalid('Multi native worker pins differ.');
  }
  final training = _multiList(p['training_scenario_hashes'], 0, 1000),
      trainingOpponents = _multiList(p['training_opponent_hashes'], 0, 1000);
  for (final list in [training, trainingOpponents]) {
    if (!list.every(_artifactDigest) || list.toSet().length != list.length) {
      _multiInvalid('Multi training lineage differs.');
    }
  }
  final profiles = <String, TrainingMultiProfile>{};
  final headers = _multiMap(
        p['multi_profiles'],
        multiModelEvaluationTargets.keys.toSet(),
      ),
      hashes = _multiMap(
        p['multi_profile_hashes'],
        multiModelEvaluationTargets.keys.toSet(),
      );
  for (final task in multiModelEvaluationTargets.keys) {
    final profile = TrainingMultiProfiles.fromJson(_multiMap(headers[task]));
    if (profile.task != task || profile.configurationHash != hashes[task]) {
      _multiInvalid('Multi shared profile identity differs.');
    }
    profiles[task] = profile;
  }
  final selectedProfile = profiles[family]!;
  if (selectedProfile.spec.hash != observationHash ||
      selectedProfile.decoder.spec.hash != actionHash) {
    _multiInvalid('Multi evaluated tensor pins differ.');
  }
  final models = _multiMap(data['family_model_hashes'], profiles.keys.toSet());
  if (!models.values.every(_artifactDigest) ||
      models[family] != modelHash ||
      data['model_hash'] != _multiHash(models) ||
      !_sameArtifactJson(data['role_model_hashes'], {
        'pursuer': models['competitive-pursuit'],
        'evader': models['competitive-pursuit'],
      })) {
    _multiInvalid('Multi actor or shared competitive role bytes differ.');
  }
  final opponents = <String, Map<String, dynamic>>{};
  for (final v in _multiList(p['opponents'], 8, 16)) {
    final o = _multiMap(v, {'id', 'kind', 'policy_hash', 'config_hash'});
    if (!_multiCatalogId(o['id']) ||
        opponents.containsKey(o['id']) ||
        !['fixed', 'withheld', 'historical'].contains(o['kind']) ||
        !_artifactDigest(o['policy_hash']) ||
        !_artifactDigest(o['config_hash']) ||
        o['kind'] == 'withheld' &&
            trainingOpponents.contains(o['policy_hash'])) {
      _multiInvalid('Multi opponent identity or withheld separation differs.');
    }
    opponents[o['id'] as String] = o;
  }
  int kindCount(String kind) =>
      opponents.values.where((o) => o['kind'] == kind).length;
  if (kindCount('fixed') != 2 ||
      kindCount('withheld') != 2 ||
      kindCount('historical') < 4 ||
      opponents.values
              .where((o) => o['kind'] == 'withheld')
              .map((o) => o['policy_hash'])
              .toSet()
              .length !=
          2) {
    _multiInvalid('Multi opponent strata differ.');
  }
  final historicalPolicies = opponents.values
      .where((o) => o['kind'] == 'historical')
      .map((o) => o['policy_hash'])
      .toSet();
  if (historicalPolicies.length != kindCount('historical')) {
    _multiInvalid('Historical pool requires distinct immutable policy bytes.');
  }
  final initial = p['initial_baseline'], previous = p['previous_checkpoint'];
  if (initial is! bool || initial && previous != null) {
    _multiInvalid('Multi initial cycling baseline differs.');
  }
  Map<String, dynamic>? previousRates;
  if (!initial) {
    final checkpoint = _multiMap(previous, {'report_hash', 'role_win_rates'});
    previousRates = _multiMap(checkpoint['role_win_rates'], {
      'pursuer',
      'evader',
    });
    if (!_artifactDigest(checkpoint['report_hash']) ||
        previousRates.values.any((v) => !_multiNumber(v) || v < 0 || v > 1)) {
      _multiInvalid('Multi previous checkpoint identity differs.');
    }
  }
  final rows = _multiList(data['episodes'], 1, 8192),
      cases = _multiList(p['cases'], 1, 128);
  final ids = <String>{}, slots = <String>{};
  final joint = <Map<String, dynamic>>[],
      grouped = <String, List<Map<String, dynamic>>>{};
  var index = 0;
  for (final v in cases) {
    final c = _multiMap(v, {
      'id',
      'family',
      'role',
      'opponent',
      'phase',
      'scenario',
      'seeds',
      'stress',
      'coverage',
    });
    final task = c['family'];
    if (!_multiCatalogId(c['id']) ||
        !ids.add(c['id'] as String) ||
        !profiles.containsKey(task) ||
        !_sameArtifactJson(c['stress'], {'miss_every': 0, 'delay_every': 0}) ||
        _multiList(c['coverage'], 0, 16).any((v) => v is! String)) {
      _multiInvalid('Multi bounded case identity differs.');
    }
    final role = c['role'], opponent = c['opponent'], phase = c['phase'];
    if (task == 'cooperative-search'
        ? role != 'joint' || opponent != null || phase != 'heldout'
        : !['pursuer', 'evader'].contains(role) ||
              !opponents.containsKey(opponent) ||
              !['heldout', 'historical'].contains(phase) ||
              (opponents[opponent]!['kind'] == 'historical') !=
                  (phase == 'historical')) {
      _multiInvalid('Multi case role/opponent phase differs.');
    }
    final spec = _multiScenario(c['scenario'], profiles[task]!, training),
        seeds = _multiList(c['seeds'], 1, 2048);
    if (seeds.any((s) => !_multiInt(s, 0, 2147483647)) ||
        seeds.toSet().length != seeds.length) {
      _multiInvalid('Multi fixed episode seeds differ.');
    }
    for (final seed in seeds) {
      final content = {...spec}
        ..remove('id')
        ..remove('partition')
        ..remove('seed');
      final slot = _multiHash([task, role, opponent, phase, content, seed]);
      if (!slots.add(slot) || index >= rows.length) {
        _multiInvalid('Multi requested slot coverage differs.');
      }
      final r = _multiMap(rows[index], {
        'index',
        'seed',
        'scenario',
        'family',
        'status',
        'success',
        'collision',
        'reward',
        'progress',
        'steps',
        'invalid_actions',
        'fallback_steps',
        'error',
        'role',
        'result',
        'opponent',
      });
      if (r['index'] != index ||
          r['seed'] != seed ||
          r['scenario'] != spec['id'] ||
          r['family'] != task ||
          r['role'] != role ||
          r['opponent'] != opponent ||
          !['completed', 'failed', 'cancelled'].contains(r['status']) ||
          !['win', 'draw', 'loss'].contains(r['result']) ||
          r['success'] is! bool ||
          r['collision'] is! bool ||
          r['success'] != (r['result'] == 'win') ||
          r['success'] == true && r['status'] != 'completed' ||
          ![
            'steps',
            'invalid_actions',
            'fallback_steps',
          ].every((k) => _multiInt(r[k])) ||
          r['fallback_steps'] > r['steps'] ||
          !_multiNumber(r['reward']) ||
          !_multiNumber(r['progress']) ||
          r['error'] != null &&
              (r['error'] is! String || (r['error'] as String).length > 1024)) {
        _multiInvalid('Multi native episode identity/outcome differs.');
      }
      if (role == 'joint') {
        joint.add(r);
      } else {
        grouped.putIfAbsent('$role/$opponent', () => []).add(r);
      }
      index++;
    }
  }
  if (index != rows.length ||
      data['requested'] != index ||
      joint.length < 200) {
    _multiInvalid('Multi independent episode denominator differs.');
  }
  final represented = <String>{};
  for (final v in _multiList(p['paired_worlds'], 1, 16)) {
    final pair = _multiMap(v, {
      'family',
      'left',
      'right',
      'seed',
      'steps',
      'actors',
    });
    final profile = profiles[pair['family']],
        actors = _multiList(pair['actors'], 1, 64);
    if (profile == null ||
        !_multiInt(pair['seed'], 0, 2147483647) ||
        !_multiInt(pair['steps'], 1, 600) ||
        !actors.every(_multiId) ||
        actors.toSet().length != actors.length) {
      _multiInvalid('Multi paired-world identity differs.');
    }
    final left = _multiScenario(pair['left'], profile, training),
        right = _multiScenario(pair['right'], profile, training);
    Map content(Map<String, dynamic> s) => {...s}
      ..remove('id')
      ..remove('partition')
      ..remove('seed');
    if (_multiHash(content(left)) == _multiHash(content(right))) {
      _multiInvalid('Multi paired worlds must differ in hidden content.');
    }
    represented.add(profile.task);
  }
  if (!represented.containsAll(profiles.keys)) {
    _multiInvalid('Multi paired evidence omits a family.');
  }
  return _finishMultiEvaluation(
    data,
    p,
    cases,
    joint,
    grouped,
    opponents,
    previousRates,
    family: family,
    modelHash: modelHash,
    receiptHash: receiptHash,
    observationHash: observationHash,
    actionHash: actionHash,
  );
}

Map<String, Object?> _multiAggregate(List<Map<String, dynamic>> rows) {
  final n = rows.length;
  if (n == 0) _multiInvalid('Multi aggregate has no episodes.');
  int count(String key, Object value) =>
      rows.where((r) => r[key] == value).length;
  int sum(String key) => rows.fold(0, (v, r) => v + (r[key] as int));
  double sumNumber(String key) =>
      rows.fold(0.0, (v, r) => v + (r[key] as num).toDouble());
  final wins = count('result', 'win'), contacts = count('collision', true);
  (double, double) interval(int successes) {
    const z = 1.959963984540054;
    final p = successes / n, d = 1 + z * z / n;
    final center = (p + z * z / (2 * n)) / d;
    final radius = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d;
    return (
      successes == 0 ? 0.0 : math.max(0, center - radius),
      successes == n ? 1.0 : math.min(1, center + radius),
    );
  }

  final w = interval(wins), c = interval(contacts);
  return {
    'requested': n,
    'completed': count('status', 'completed'),
    'failed': count('status', 'failed'),
    'cancelled': count('status', 'cancelled'),
    'successes': wins,
    'success_denominator': n,
    'success_rate': wins / n,
    'success_lower95': w.$1,
    'success_upper95': w.$2,
    'collisions': contacts,
    'collision_denominator': n,
    'collision_rate': contacts / n,
    'collision_lower95': c.$1,
    'collision_upper95': c.$2,
    'reward_sum': sumNumber('reward'),
    'progress_sum': sumNumber('progress'),
    'invalid_actions': sum('invalid_actions'),
    'fallback_steps': sum('fallback_steps'),
    'wins': wins,
    'draws': count('result', 'draw'),
    'losses': count('result', 'loss'),
    'win_denominator': n,
    'win_rate': wins / n,
    'win_lower95': w.$1,
    'win_upper95': w.$2,
  };
}

void _multiCheckAggregate(Object? value, Map<String, Object?> actual) {
  final recorded = _multiMap(value, actual.keys.toSet());
  for (final key in actual.keys) {
    final expected = actual[key], v = recorded[key];
    if (expected is int
        ? v != expected || v is! int
        : !_multiNumber(v) ||
              ((v as num).toDouble() - (expected as num).toDouble()).abs() >
                  1e-12) {
      _multiInvalid(
        'Multi aggregate rate/count/confidence interval was altered.',
      );
    }
  }
}

ModelEvaluation _finishMultiEvaluation(
  Map<String, dynamic> d,
  Map<String, dynamic> p,
  List<dynamic> cases,
  List<Map<String, dynamic>> joint,
  Map<String, List<Map<String, dynamic>>> grouped,
  Map<String, Map<String, dynamic>> opponents,
  Map<String, dynamic>? previous, {
  required String family,
  required String modelHash,
  required String receiptHash,
  required String observationHash,
  required String actionHash,
}) {
  final jointMetrics = _multiAggregate(joint),
      roles = <String, Map<String, Object?>>{};
  final metrics = _multiMap(
        d['metrics'],
        multiModelEvaluationTargets.keys.toSet(),
      ),
      recordedRoles = _multiMap(metrics['competitive-pursuit'], {
        'pursuer',
        'evader',
      }),
      opponentMetrics = _multiMap(d['opponent_metrics'], {'pursuer', 'evader'}),
      historyMetrics = _multiMap(d['historical_metrics'], {
        'pursuer',
        'evader',
      }),
      historyRoles = _multiMap(d['historical_role_metrics'], {
        'pursuer',
        'evader',
      }),
      seeds = _multiMap(
        d['layout_seed_counts'],
        multiModelEvaluationTargets.keys.toSet(),
      ),
      roleSeeds = _multiMap(seeds['competitive-pursuit'], {
        'pursuer',
        'evader',
      });
  _multiCheckAggregate(metrics['cooperative-search'], jointMetrics);
  var accepted = d['status'] == 'passed';
  bool healthy(Map<String, Object?> m, int minimum, {bool contact = true}) =>
      (m['requested'] as int) >= minimum &&
      m['completed'] == m['requested'] &&
      m['failed'] == 0 &&
      m['cancelled'] == 0 &&
      m['invalid_actions'] == 0 &&
      (!contact || (m['collision_upper95'] as double) <= .02);
  var gates =
      healthy(jointMetrics, 200) &&
      (jointMetrics['success_rate'] as double) >= .95 &&
      (jointMetrics['success_lower95'] as double) >= .90;
  final jointSeeds = joint.map((r) => r['seed']).toSet().length;
  if (seeds['cooperative-search'] != jointSeeds) {
    _multiInvalid('Multi joint seed count differs.');
  }
  gates = gates && jointSeeds >= 20;
  for (final role in ['pursuer', 'evader']) {
    final held = <Map<String, dynamic>>[], history = <Map<String, dynamic>>[];
    final heldIds = opponents.values
            .where((o) => o['kind'] != 'historical')
            .map((o) => o['id'] as String)
            .toSet(),
        historyIds = opponents.values
            .where((o) => o['kind'] == 'historical')
            .map((o) => o['id'] as String)
            .toSet();
    final recordedHeld = _multiMap(opponentMetrics[role], heldIds),
        recordedHistory = _multiMap(historyMetrics[role], historyIds);
    for (final o in opponents.values) {
      final rows =
          grouped['$role/${o['id']}'] ?? const <Map<String, dynamic>>[];
      if (rows.length != 50) {
        _multiInvalid('Multi role requires 50 slots per opponent.');
      }
      final m = _multiAggregate(rows), historical = o['kind'] == 'historical';
      _multiCheckAggregate(
        (historical ? recordedHistory : recordedHeld)[o['id']],
        m,
      );
      gates =
          gates &&
          healthy(m, 50, contact: false) &&
          (m['win_rate'] as double) >= (historical ? .40 : .50);
      (historical ? history : held).addAll(rows);
    }
    final roleMetric = _multiAggregate(held),
        historyMetric = _multiAggregate(history);
    roles[role] = roleMetric;
    _multiCheckAggregate(recordedRoles[role], roleMetric);
    _multiCheckAggregate(historyRoles[role], historyMetric);
    final seedCount = held.map((r) => r['seed']).toSet().length;
    if (roleSeeds[role] != seedCount) {
      _multiInvalid('Multi role seed count differs.');
    }
    gates =
        gates &&
        seedCount >= 20 &&
        healthy(roleMetric, 200) &&
        healthy(historyMetric, 200) &&
        (roleMetric['win_rate'] as double) >= .60 &&
        (roleMetric['win_lower95'] as double) >= .50 &&
        (previous == null ||
            (previous[role] as num) - (roleMetric['win_rate'] as double) <=
                .10);
  }
  for (final k in [
    'hidden_state_leaks',
    'reward_exploits',
    'stale_outputs',
    'worker_failures',
  ]) {
    if (d[k] != null && !_multiInt(d[k])) {
      _multiInvalid('Multi failure counter differs.');
    }
    gates = gates && d[k] == 0;
  }
  final exits = _multiList(d['worker_exit_codes'], 0, 64),
      reasons = _multiList(d['reasons'], 0, 256);
  if (exits.any((v) => v != null && v is! int) ||
      reasons.any((v) => v is! String)) {
    _multiInvalid('Multi close/acceptance reasons differ.');
  }
  gates =
      gates &&
      exits.isNotEmpty &&
      exits.every((v) => v == 0) &&
      [
        ...joint,
        ...grouped.values.expand((v) => v),
      ].every((r) => r['status'] != 'completed' || (r['steps'] as int) > 0);
  if (accepted != gates ||
      accepted && reasons.isNotEmpty ||
      !accepted && reasons.isEmpty) {
    _multiInvalid(
      'Multi receipt claims acceptance inconsistent with fixed gates.',
    );
  }
  return ModelEvaluation._(
    modelHash: modelHash,
    observationHash: observationHash,
    actionHash: actionHash,
    receiptHash: receiptHash,
    planHash: d['plan_hash'] as String,
    accepted: accepted,
    provider: d['provider'] as String,
    fixedHz: 50,
    schemaVersion: 2,
    roleMetrics: family == 'competitive-pursuit' ? roles : const {},
    successRate: family == 'cooperative-search'
        ? jointMetrics['success_rate'] as double
        : roles.values.map((m) => m['win_rate'] as double).reduce(math.min),
    cases: [
      for (final c in cases.where((c) => c['family'] == family))
        Map<String, Object?>.from(c as Map),
    ],
  );
}
