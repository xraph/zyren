part of '../../zyren_game.dart';

/// Feed overlap transitions from the existing physics query owner.
final class GameTrigger {
  final String id;
  final bool oncePerActor;
  final int capacity;
  final Set<GameEntityHandle> _inside = {}, _credited = {};
  GameTrigger({
    required String id,
    this.oncePerActor = false,
    this.capacity = 10000,
  }) : id = _id(id) {
    _limit(capacity, 10000, 'trigger capacity');
  }
  bool enter(GameEntityHandle actor) {
    if (_inside.contains(actor) ||
        _inside.length >= capacity ||
        oncePerActor &&
            (_credited.contains(actor) || _credited.length >= capacity)) {
      return false;
    }
    _inside.add(actor);
    if (oncePerActor) _credited.add(actor);
    return true;
  }

  bool exit(GameEntityHandle actor) => _inside.remove(actor);
  void prune(GameEntityTable entities) {
    _inside.removeWhere((actor) => !entities.isAlive(actor));
    _credited.removeWhere((actor) => !entities.isAlive(actor));
  }

  void reset() {
    _inside.clear();
    _credited.clear();
  }
}
