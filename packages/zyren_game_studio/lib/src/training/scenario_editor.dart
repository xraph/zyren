part of '../../training.dart';

/// Editable JSON-compatible YAML, bounded before the Python validator runs.
final class TrainingScenarioDocument {
  final Map<String, dynamic> _data;
  TrainingScenarioDocument(Map<String, dynamic> data)
    : _data = jsonDecode(jsonEncode(data)) {
    if (utf8.encode(jsonEncode(data)).length > 1048576 ||
        data['scenarios'] is! List ||
        (data['scenarios'] as List).isEmpty ||
        (data['scenarios'] as List).length > 64) {
      throw ArgumentError('Invalid scenario document.');
    }
  }
  Map<String, dynamic> get data => jsonDecode(jsonEncode(_data));
  List<Map<String, dynamic>> get scenarios => (_data['scenarios'] as List)
      .map((v) => Map<String, dynamic>.from(v))
      .toList();
  TrainingScenarioDocument withScenario(
    int index,
    Map<String, dynamic> scenario,
  ) {
    if (!['train', 'validation', 'test'].contains(scenario['partition']) ||
        scenario['seed'] is! int ||
        scenario['max_steps'] is! int ||
        scenario['max_steps'] < 1 ||
        scenario['max_steps'] > 1000000 ||
        !_digest(scenario['observation_schema_hash']) ||
        !_digest(scenario['action_schema_hash'])) {
      throw ArgumentError('Scenario identity, split or bounds differ.');
    }
    final next = data;
    (next['scenarios'] as List)[index] = scenario;
    return TrainingScenarioDocument(next);
  }

  Future<void> save(String projectDirectory, String path) async {
    final root = await Directory(projectDirectory).resolveSymbolicLinks();
    await _scopedPath(root, path);
    final file = File(path);
    await file.parent.create(recursive: true);
    await file.writeAsString(
      '${const JsonEncoder.withIndent('  ').convert(_data)}\n',
      flush: true,
    );
  }
}
