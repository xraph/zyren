part of '../../zyren_game.dart';

final class GameSceneIdentity {
  final String id, pin;
  GameSceneIdentity(String id, String pin) : id = _id(id), pin = _id(pin);
  Map<String, Object?> toJson() => {'id': id, 'pin': pin};
  factory GameSceneIdentity.fromJson(Map<String, Object?> value) =>
      GameSceneIdentity(_string(value['id']), _string(value['pin']));
}

final class GameLevel {
  final String id;
  final GameSceneIdentity scene;
  final List<GameEntityRecord> entities;
  GameLevel({
    required String id,
    required this.scene,
    required List<GameEntityRecord> entities,
  }) : id = _id(id),
       entities = List.unmodifiable(entities) {
    if (entities.length > 10000) {
      throw const FormatException('Level entity limit exceeded.');
    }
  }
  Map<String, Object?> toJson() => {
    'id': id,
    'scene': scene.toJson(),
    'entities': entities.map((e) => e.toJson()).toList(),
  };
  factory GameLevel.fromJson(Map<String, Object?> value) => GameLevel(
    id: _string(value['id']),
    scene: GameSceneIdentity.fromJson(_map(value['scene'])),
    entities: _list(
      value['entities'],
    ).map((e) => GameEntityRecord.fromJson(_map(e))).toList(),
  );
}

/// Schema-one project data. Decoding never invokes component factories.
final class GameProject {
  static const currentSchemaVersion = 1;
  final int schemaVersion;
  final String id, startupLevel;
  final List<GameLevel> levels;
  final Map<String, Object?> inputMaps, componentSchemas, behaviorReferences;
  final Map<String, Object?> modelReferences, buildProfiles;
  final List<String> capabilityRequirements;
  final GameRegistry registry;
  final List<String> activationProblems;

  factory GameProject({
    int schemaVersion = currentSchemaVersion,
    required String id,
    required String startupLevel,
    required List<GameLevel> levels,
    required GameRegistry registry,
    Map<String, Object?> inputMaps = const {},
    Map<String, Object?> componentSchemas = const {},
    Map<String, Object?> behaviorReferences = const {},
    Map<String, Object?> modelReferences = const {},
    Map<String, Object?> buildProfiles = const {},
    List<String> capabilityRequirements = const [],
  }) {
    if (schemaVersion != currentSchemaVersion) {
      throw const FormatException('Unsupported game project schema.');
    }
    _id(id);
    _id(startupLevel);
    final frozen = registry.snapshot();
    if (levels.length > frozen.limits.maxLevels) {
      throw const FormatException('Level limit exceeded.');
    }
    final ids = <String>{};
    final checked = <GameLevel>[];
    final problems = <String>[];
    var entityCount = 0;
    for (final level in levels) {
      if (!ids.add(level.id)) {
        throw FormatException('Duplicate level ID: ${level.id}.');
      }
      entityCount += level.entities.length;
      if (entityCount > frozen.limits.maxEntities) {
        throw const FormatException('Project entity limit exceeded.');
      }
      final entities = _validateEntities(level.entities, frozen);
      checked.add(
        GameLevel(id: level.id, scene: level.scene, entities: entities),
      );
      for (final entity in entities) {
        for (final component in entity.components) {
          if (component.required && !frozen.supports(component)) {
            problems.add(
              '${level.id}/${entity.id}: unsupported ${component.type}@${component.version}',
            );
          }
        }
      }
    }
    if (!ids.contains(startupLevel)) {
      throw const FormatException('Startup level does not exist.');
    }
    if (capabilityRequirements.length > 256) {
      throw const FormatException('Capability limit exceeded.');
    }
    return GameProject._(
      schemaVersion,
      id,
      startupLevel,
      List.unmodifiable(checked),
      _json(inputMaps),
      _json(componentSchemas),
      _json(behaviorReferences),
      _json(modelReferences),
      _json(buildProfiles),
      List.unmodifiable(capabilityRequirements.map(_id)),
      frozen,
      List.unmodifiable(problems),
    );
  }

  GameProject._(
    this.schemaVersion,
    this.id,
    this.startupLevel,
    this.levels,
    this.inputMaps,
    this.componentSchemas,
    this.behaviorReferences,
    this.modelReferences,
    this.buildProfiles,
    this.capabilityRequirements,
    this.registry,
    this.activationProblems,
  );

  bool get canActivate => activationProblems.isEmpty;
  void requireActivation() {
    if (!canActivate) throw StateError(activationProblems.join('\n'));
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'id': id,
    'startupLevel': startupLevel,
    'levels': levels.map((e) => e.toJson()).toList(),
    'inputMaps': inputMaps,
    'componentSchemas': componentSchemas,
    'behaviorReferences': behaviorReferences,
    'modelReferences': modelReferences,
    'buildProfiles': buildProfiles,
    'capabilityRequirements': capabilityRequirements,
  };

  String encode() {
    final source = jsonEncode(toJson());
    _checkSource(source);
    return source;
  }

  factory GameProject.decode(String source, GameRegistry registry) {
    _checkSource(source);
    try {
      final value = _map(jsonDecode(source));
      final levels = _list(value['levels']);
      if (levels.length > registry.limits.maxLevels) {
        throw const FormatException('Level limit exceeded.');
      }
      var entities = 0;
      for (final level in levels) {
        final records = _list(_map(level)['entities']);
        entities += records.length;
        if (entities > registry.limits.maxEntities) {
          throw const FormatException('Project entity limit exceeded.');
        }
        for (final entity in records) {
          if (_list(_map(entity)['components'] ?? const []).length >
              registry.limits.maxComponentsPerEntity) {
            throw const FormatException(
              'Components per entity limit exceeded.',
            );
          }
        }
      }
      return GameProject(
        schemaVersion: _integer(value['schemaVersion']),
        id: _string(value['id']),
        startupLevel: _string(value['startupLevel']),
        registry: registry,
        levels: levels.map((e) => GameLevel.fromJson(_map(e))).toList(),
        inputMaps: _map(value['inputMaps'] ?? const <String, Object?>{}),
        componentSchemas: _map(
          value['componentSchemas'] ?? const <String, Object?>{},
        ),
        behaviorReferences: _map(
          value['behaviorReferences'] ?? const <String, Object?>{},
        ),
        modelReferences: _map(
          value['modelReferences'] ?? const <String, Object?>{},
        ),
        buildProfiles: _map(
          value['buildProfiles'] ?? const <String, Object?>{},
        ),
        capabilityRequirements: _list(
          value['capabilityRequirements'] ?? const [],
        ).map(_string).toList(),
      );
    } on FormatException {
      rethrow;
    } on TypeError {
      throw const FormatException('Malformed game project fields.');
    }
  }
}

void _checkSource(String source) {
  if (source.length > GameLimits.maxSourceBytes ||
      utf8.encode(source).length > GameLimits.maxSourceBytes) {
    throw const FormatException('Game project exceeds source byte limit.');
  }
}
