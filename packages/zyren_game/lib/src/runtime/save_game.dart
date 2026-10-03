part of '../../zyren_game.dart';

/// Stage native resources synchronously. Discard releases an uncommitted stage.
/// Commit transfers it into the live system. Rollback uses another prepared stage.
abstract class GameStateCodec<T extends Object> {
  String get id;
  int get version;
  Map<String, Object?> capture(GameSession session);
  T prepare(GameSession session, Map<String, Object?> data);
  void commit(GameSession session, T prepared);
  void discard(T prepared) {}
}

final class GameSave {
  static const currentSchemaVersion = 2;
  final int schemaVersion = currentSchemaVersion;
  final String projectId, buildId, levelId;
  final int projectSchema, seed, tick;
  final bool paused;
  final List<GameEntityRecord> entities;
  final Map<String, Object?> models, state;
  final Map<String, int> codecVersions;
  GameSave({
    required String projectId,
    required String buildId,
    required String levelId,
    required this.projectSchema,
    required this.seed,
    required this.tick,
    required this.paused,
    required List<GameEntityRecord> entities,
    required Map<String, Object?> models,
    required Map<String, Object?> state,
    required Map<String, int> codecVersions,
  }) : projectId = _id(projectId),
       buildId = _id(buildId),
       levelId = _id(levelId),
       entities = List.unmodifiable(entities),
       models = _json(models),
       state = _json(state),
       codecVersions = Map.unmodifiable(codecVersions) {
    if (projectSchema < 1 ||
        tick < 0 ||
        entities.length > 10000 ||
        state.length > 256 ||
        state.keys.toSet().difference(codecVersions.keys.toSet()).isNotEmpty ||
        codecVersions.keys.toSet().difference(state.keys.toSet()).isNotEmpty ||
        codecVersions.values.any((v) => v < 1)) {
      throw FormatException('Invalid save envelope.');
    }
    for (final id in codecVersions.keys) {
      _id(id);
    }
  }
  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'projectId': projectId,
    'projectSchema': projectSchema,
    'buildId': buildId,
    'levelId': levelId,
    'seed': seed,
    'tick': tick,
    'paused': paused,
    'entities': entities.map((e) => e.toJson()).toList(),
    'models': models,
    'state': state,
    'codecVersions': codecVersions,
  };
  String encode() {
    final source = jsonEncode(toJson());
    _checkSource(source);
    return source;
  }

  factory GameSave.decode(
    String source, {
    Map<int, Map<String, Object?> Function(Map<String, Object?>)> migrations =
        const {},
  }) {
    _checkSource(source);
    var json = _map(jsonDecode(source));
    final visited = <int>{};
    while (json['schemaVersion'] != currentSchemaVersion) {
      final version = _integer(json['schemaVersion']);
      final migration = migrations[version];
      if (!visited.add(version) || migration == null || visited.length > 16) {
        throw FormatException('Unsupported game save schema.');
      }
      json = migration(_json(json));
      _checkSource(jsonEncode(json));
    }
    try {
      return GameSave(
        projectId: _string(json['projectId']),
        projectSchema: _integer(json['projectSchema']),
        buildId: _string(json['buildId']),
        levelId: _string(json['levelId']),
        seed: _integer(json['seed']),
        tick: _integer(json['tick']),
        paused: json['paused'] as bool,
        entities: _list(
          json['entities'],
        ).map((e) => GameEntityRecord.fromJson(_map(e))).toList(),
        models: _map(json['models']),
        state: _map(json['state']),
        codecVersions: _map(
          json['codecVersions'],
        ).map((k, v) => MapEntry(k, _integer(v))),
      );
    } on TypeError {
      throw FormatException('Malformed game save.');
    }
  }
}
