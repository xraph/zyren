part of '../../zyren_game.dart';

/// Payload types belong to the host and should be immutable value objects.
final class GameCommand<T extends Object> {
  final GameEntityHandle target;
  final int applicationTick;
  final T payload;
  GameCommand(this.target, this.applicationTick, this.payload) {
    if (applicationTick < 0) {
      throw RangeError.value(applicationTick, 'applicationTick');
    }
  }
}

/// Admission and application both reject stale generations. Late commands expire.
final class GameCommandQueue<T extends Object> {
  final GameLimits limits;
  final List<GameCommand<T>> _commands = [];
  int _lastTick = -1;
  GameCommandQueue({GameLimits? limits}) : limits = limits ?? GameLimits();
  int get length => _commands.length;
  bool enqueue(GameCommand<T> command, GameEntityTable entities) {
    if (_commands.length >= limits.maxQueuedCommands ||
        !entities.isAlive(command.target) ||
        command.applicationTick <= _lastTick) {
      return false;
    }
    _commands.add(command);
    return true;
  }

  List<GameCommand<T>> drain(int tick, GameEntityTable entities) {
    if (tick < 0) throw RangeError.value(tick, 'tick');
    if (tick <= _lastTick) {
      throw StateError('Command application ticks must increase.');
    }
    _lastTick = tick;
    final due = <GameCommand<T>>[];
    _commands.removeWhere((command) {
      if (command.applicationTick > tick) return false;
      if (command.applicationTick == tick && entities.isAlive(command.target)) {
        due.add(command);
      }
      return true;
    });
    return List.unmodifiable(due);
  }

  int cancelTarget(GameEntityHandle target) {
    final before = _commands.length;
    _commands.removeWhere((command) => command.target == target);
    return before - _commands.length;
  }

  void clear() => _commands.clear();
}
