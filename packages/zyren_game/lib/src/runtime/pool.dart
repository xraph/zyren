part of '../../zyren_game.dart';

/// A pool retains bounded immutable spawn recipes, never live native handles.
final class GamePool {
  final GameEntityTable entities;
  final int capacity;
  final void Function(GameEntityHandle) reset;
  final Map<String, GameEntityRecord> _retired = {};
  GamePool({required this.entities, required this.reset, this.capacity = 256}) {
    _limit(capacity, 10000, 'capacity');
  }
  int get retained => _retired.length;
  bool retire(GameEntityHandle handle) {
    final entity = entities.entity(handle);
    if (entity == null) return false;
    if (!_retired.containsKey(handle.id) && _retired.length >= capacity) {
      throw StateError('Pool is full.');
    }
    reset(handle); // Reset beliefs, input and physics before retiring identity.
    _retired[handle.id] = GameEntityRecord(
      id: handle.id,
      components: entity.components,
    );
    return entities.despawn(handle);
  }

  GameEntityHandle acquire(String id, {List<GameComponentRecord>? components}) {
    final record = _retired[id];
    if (record == null) throw StateError('Entity is not pooled.');
    final handle = entities.spawn(
      id,
      components: components ?? record.components,
    );
    _retired.remove(id);
    return handle;
  }

  void clear() => _retired.clear();
}
