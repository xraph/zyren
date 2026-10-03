part of '../../zyren_game.dart';

final class GameEntityHandle {
  final String id;
  final int generation;
  GameEntityHandle(String id, this.generation) : id = _id(id) {
    if (generation < 1) throw RangeError.value(generation, 'generation');
  }
  @override
  bool operator ==(Object other) =>
      other is GameEntityHandle &&
      id == other.id &&
      generation == other.generation;
  @override
  int get hashCode => Object.hash(id, generation);
  @override
  String toString() => '$id@$generation';
}

final class GameEntityRecord {
  final String id;
  final String? nodeId;
  final List<GameComponentRecord> components;
  final Object? _spawnOrigin;
  GameEntityRecord({
    required String id,
    String? nodeId,
    List<GameComponentRecord> components = const [],
  }) : id = _id(id),
       nodeId = nodeId == null ? null : _id(nodeId),
       components = List.unmodifiable(components),
       _spawnOrigin = null {
    if (components.length > 64) {
      throw const FormatException('Component limit exceeded.');
    }
    final types = <String>{};
    for (final component in components) {
      if (!types.add(component.type)) {
        throw FormatException('Duplicate component: ${component.type}.');
      }
    }
  }
  GameEntityRecord._instantiated(GameEntityRecord source, this._spawnOrigin)
    : id = source.id,
      nodeId = source.nodeId,
      components = source.components;

  Map<String, Object?> toJson() => {
    'id': id,
    if (nodeId != null) 'nodeId': nodeId,
    'components': components.map((c) => c.toJson()).toList(),
  };
  factory GameEntityRecord.fromJson(Map<String, Object?> value) =>
      GameEntityRecord(
        id: _string(value['id']),
        nodeId: value['nodeId'] == null ? null : _string(value['nodeId']),
        components: _list(
          value['components'] ?? const [],
        ).map((c) => GameComponentRecord.fromJson(_map(c))).toList(),
      );
}

final class GameRuntimeEntity {
  final GameEntityHandle handle;
  final List<GameComponentRecord> components;
  GameRuntimeEntity._(this.handle, List<GameComponentRecord> components)
    : components = List.unmodifiable(components);
}

/// Live entities and retained generation history are both bounded.
final class GameEntityTable {
  final GameLimits limits;
  final Map<String, GameRuntimeEntity> _entities = {};
  final Map<String, int> _generations = {};
  int _highWater = 0;
  GameEntityTable({GameLimits? limits}) : limits = limits ?? GameLimits();
  int get length => _entities.length;
  List<GameRuntimeEntity> get entities => List.unmodifiable(_entities.values);

  GameEntityHandle spawn(
    String id, {
    List<GameComponentRecord> components = const [],
  }) {
    _id(id);
    if (_entities.containsKey(id)) {
      throw StateError('Entity is already alive: $id.');
    }
    if (_entities.length >= limits.maxEntities) {
      throw StateError('Entity table is full.');
    }
    if (components.length > limits.maxComponentsPerEntity) {
      throw StateError('Entity component limit exceeded.');
    }
    final record = GameEntityRecord(id: id, components: components);
    final previous = _generations[id];
    final generation = previous == null ? _highWater + 1 : previous + 1;
    if (generation > 0x1fffffffffffff) {
      throw StateError('Entity generation exhausted.');
    }
    final handle = GameEntityHandle(id, generation);
    if (previous == null && _generations.length >= limits.maxEntities) {
      final retired = _generations.keys.firstWhere(
        (key) => !_entities.containsKey(key),
      );
      _generations.remove(retired);
    }
    _generations.remove(id);
    _generations[id] = generation;
    if (generation > _highWater) _highWater = generation;
    _entities[id] = GameRuntimeEntity._(handle, record.components);
    return handle;
  }

  bool isAlive(GameEntityHandle handle) =>
      _entities[handle.id]?.handle == handle;
  GameRuntimeEntity? entity(GameEntityHandle handle) =>
      isAlive(handle) ? _entities[handle.id] : null;
  bool despawn(GameEntityHandle handle) {
    if (!isAlive(handle)) return false;
    _entities.remove(handle.id);
    return true;
  }
}
