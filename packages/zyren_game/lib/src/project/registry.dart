part of '../../zyren_game.dart';

final class GameRegistry {
  final GameLimits limits;
  final Map<String, GameComponentCodec<Object>> _codecs;
  final bool _frozen;

  GameRegistry({GameLimits? limits})
    : limits = limits ?? GameLimits(),
      _codecs = {},
      _frozen = false;
  GameRegistry._(this.limits, this._codecs) : _frozen = true;

  void registerComponent(GameComponentCodec<Object> codec) {
    if (_frozen) throw StateError('This registry snapshot is frozen.');
    final type = _id(codec.type);
    if (codec.version < 1) {
      throw const FormatException('Invalid codec version.');
    }
    if (_codecs.containsKey(type)) {
      throw StateError('Duplicate component type: $type.');
    }
    if (_codecs.length >= limits.maxComponentTypes) {
      throw StateError('Component registry is full.');
    }
    _codecs[type] = codec;
  }

  /// Projects capture registrations so a later registration cannot change activation.
  GameRegistry snapshot() => GameRegistry._(limits, Map.unmodifiable(_codecs));

  GameComponentRecord normalize(GameComponentRecord record) {
    final codec = _codecs[record.type];
    if (codec == null || record.version > codec.version) return record;
    final normalized = record.version == codec.version
        ? record
        : GameComponentRecord(
            record.type,
            codec.version,
            codec.migrate(record.version, record.data),
            required: record.required,
          );
    codec.validate(normalized.data);
    return normalized;
  }

  bool supports(GameComponentRecord record) =>
      _codecs[record.type]?.version == record.version;

  List<GameLocalReference> references(GameComponentRecord record) {
    if (!supports(record)) return const [];
    final result = <GameLocalReference>[];
    for (final reference in _codecs[record.type]!.localReferences(
      record.data,
    )) {
      if (result.length >= GameLimits.maxJsonNodes) {
        throw const FormatException('Too many component references.');
      }
      if (_readPath(record.data, reference.path) != reference.targetId) {
        throw const FormatException(
          'Reference path does not identify its target.',
        );
      }
      result.add(reference);
    }
    return List.unmodifiable(result);
  }

  Object? construct(GameComponentRecord record) {
    final normalized = normalize(record);
    if (!supports(normalized)) {
      if (normalized.required) {
        throw StateError('Unsupported required component: ${normalized.type}.');
      }
      return null;
    }
    return _codecs[normalized.type]!.factory(normalized.data);
  }
}

Object? _readPath(Object? data, List<Object> path) {
  var value = data;
  for (final segment in path) {
    if (segment is String && value is Map && value.containsKey(segment)) {
      value = value[segment];
    } else if (segment is int && value is List && segment < value.length) {
      value = value[segment];
    } else {
      throw const FormatException('Local reference path does not exist.');
    }
  }
  return value;
}

List<GameEntityRecord> _validateEntities(
  List<GameEntityRecord> entities,
  GameRegistry registry,
) {
  if (entities.length > registry.limits.maxEntities) {
    throw const FormatException('Entity limit exceeded.');
  }
  final ids = <String>{};
  final normalized = <GameEntityRecord>[];
  for (final entity in entities) {
    if (!ids.add(entity.id)) {
      throw FormatException('Duplicate entity ID: ${entity.id}.');
    }
    if (entity.components.length > registry.limits.maxComponentsPerEntity) {
      throw const FormatException('Components per entity limit exceeded.');
    }
    normalized.add(
      GameEntityRecord(
        id: entity.id,
        nodeId: entity.nodeId,
        components: entity.components.map(registry.normalize).toList(),
      ),
    );
  }
  for (final entity in normalized) {
    for (final component in entity.components) {
      for (final reference in registry.references(component)) {
        if (!ids.contains(reference.targetId)) {
          throw FormatException(
            'Dangling local entity reference: ${reference.targetId}.',
          );
        }
      }
    }
  }
  return List.unmodifiable(normalized);
}
