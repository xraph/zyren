part of '../../zyren_game.dart';

final class GameEvent<T extends Object> {
  final int tick, sequence;
  final T payload;
  const GameEvent(this.tick, this.sequence, this.payload);
}

final class GameEventSubscription {
  void Function()? _cancel;
  GameEventSubscription._(this._cancel);
  void cancel() {
    _cancel?.call();
    _cancel = null;
  }
}

/// Bounded event journal. Drain after consuming a frame or training step.
final class GameEventBus {
  final int capacity;
  final List<GameEvent<Object>> _journal = [];
  final Queue<GameEvent<Object>> _pending = Queue();
  final Map<int, void Function(GameEvent<Object>)> _listeners = {};
  int _sequence = 0, _listenerId = 0;
  bool _dispatching = false, _closed = false;
  GameEventBus({this.capacity = 4096}) {
    _limit(capacity, 65536, 'capacity');
  }
  bool get canEmit =>
      !_closed && _journal.length < capacity && _pending.length < capacity;

  GameEventSubscription listen(void Function(GameEvent<Object>) listener) {
    if (_closed) throw StateError('Event bus is closed.');
    if (_listeners.length >= 1024) {
      throw StateError('Event listener limit exceeded.');
    }
    final id = _listenerId++;
    _listeners[id] = listener;
    return GameEventSubscription._(() => _listeners.remove(id));
  }

  void emit(int tick, Object payload) {
    if (_closed) throw StateError('Event bus is closed.');
    if (tick < 0) throw RangeError.value(tick, 'tick');
    if (_journal.length >= capacity || _pending.length >= capacity) {
      throw StateError('Event journal is full.');
    }
    final event = GameEvent(tick, _sequence++, payload);
    _journal.add(event);
    _pending.add(event);
    if (_dispatching) return;
    _dispatching = true;
    try {
      var delivered = 0;
      while (_pending.isNotEmpty) {
        if (++delivered > capacity) {
          throw StateError('Recursive event delivery limit exceeded.');
        }
        final next = _pending.removeFirst();
        for (final id in _listeners.keys.toList()) {
          _listeners[id]?.call(next);
        }
      }
    } finally {
      _pending.clear();
      _dispatching = false;
    }
  }

  List<GameEvent<Object>> drain() {
    final result = List<GameEvent<Object>>.unmodifiable(_journal);
    _journal.clear();
    return result;
  }

  void close() {
    _closed = true;
    _pending.clear();
    _listeners.clear();
    _journal.clear();
  }
}
