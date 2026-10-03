part of '../../zyren_game.dart';

/// One simulation clock, shared by realtime play, replay and training.
final class GameSession {
  final CompiledGameProject project;
  final int seed;
  final GameClock clock;
  final GameEntityTable entities;
  final GameCommandQueue<Object> commands;
  final GameEventBus events;
  final List<GameSystem> _systems;
  final List<GameSystem> _started = [];
  final Set<String> _removed = {};
  final Queue<void Function(GameSession)> _mutations = Queue();
  final Map<int, void Function()> _stateListeners = {};
  List<GameCommand<Object>> _currentCommands = const [];
  int _tick = 0, _epoch = 0, _listenerId = 0, _nextSystemStart = 0;
  bool _initialized = false,
      _stepping = false,
      _paused = false,
      _closed = false;
  Object? _fault;
  Future<void>? _closing;
  GameSession({
    required this.project,
    required this.seed,
    int? fixedHz,
    int maxCatchUpSteps = 8,
    List<GameSystem> systems = const [],
  }) : clock = GameClock(
         fixedHz: fixedHz ?? project.fixedHz,
         maxCatchUpSteps: maxCatchUpSteps,
       ),
       entities = GameEntityTable(limits: project.project.registry.limits),
       commands = GameCommandQueue(limits: project.project.registry.limits),
       events = GameEventBus(),
       _systems = _orderSystems(systems) {
    if (clock.fixedHz != project.fixedHz) {
      throw ArgumentError(
        'Session and compiled project fixed rates must match.',
      );
    }
    for (final entry in project.systemVersions.entries) {
      if (!_systems.any((s) => s.id == entry.key && s.version == entry.value)) {
        throw StateError(
          'Required system version is unavailable: ${entry.key}.',
        );
      }
    }
  }
  int get tick => _tick;
  int get epoch => _epoch;
  int get fixedHz => clock.fixedHz;
  double get stepSeconds => clock.stepSeconds;
  double get droppedSeconds => clock.droppedSeconds;
  bool get paused => _paused;
  bool get isClosed => _closed;
  Object? get fault => _fault;
  List<GameCommand<Object>> get currentCommands => _currentCommands;
  GameEventSubscription listenState(void Function() listener) {
    _requireOpen();
    if (_stateListeners.length >= 1024) {
      throw StateError('Session listener limit exceeded.');
    }
    final id = _listenerId++;
    _stateListeners[id] = listener;
    return GameEventSubscription._(() => _stateListeners.remove(id));
  }

  void _notify() {
    for (final id in _stateListeners.keys.toList()) {
      _stateListeners[id]?.call();
    }
  }

  void _requireOpen() {
    if (_closed) throw StateError('Session is closed.');
    if (_fault != null) throw StateError('Session has failed: $_fault');
  }

  /// Spawn/despawn transactions run at the beginning of the next tick.
  void enqueueMutation(void Function(GameSession) mutation) {
    _requireOpen();
    if (_mutations.length >=
        project.project.registry.limits.maxQueuedCommands) {
      throw StateError('Mutation queue is full.');
    }
    _mutations.add(mutation);
  }

  bool removeSystem(String id) {
    _requireOpen();
    if (_removed.contains(id) || !_systems.any((s) => s.id == id)) return false;
    if (_systems.any(
      (s) => !_removed.contains(s.id) && s.dependencies.contains(id),
    )) {
      throw StateError('System has active dependents: $id.');
    }
    _removed.add(id);
    return true;
  }

  void _start() {
    if (!_initialized) {
      _initialized = true;
      final level = project.levels.singleWhere(
        (l) => l.id == project.project.startupLevel,
      );
      for (final entity in level.entities) {
        entities.spawn(entity.id, components: entity.components);
      }
    }
    while (_nextSystemStart < _systems.length && !_paused && !_closed) {
      final system = _systems[_nextSystemStart++];
      if (_removed.contains(system.id)) continue;
      _started.add(system);
      system.start(this);
    }
  }

  void step() {
    _requireOpen();
    if (_stepping) throw StateError('Session step is not reentrant.');
    if (_paused) return;
    _stepping = true;
    try {
      _start();
      if (_closed || _paused) return;
      _tick++;
      final mutations = _mutations.toList();
      _mutations.clear();
      for (final mutation in mutations) {
        if (_closed || _paused) break;
        mutation(this);
      }
      if (_closed || _paused) return;
      _currentCommands = commands.drain(_tick, entities);
      for (final system in _systems) {
        if (_closed || _paused) break;
        if (!_removed.contains(system.id)) system.fixedUpdate(this);
      }
      _notify();
    } catch (error) {
      _fail(error);
      rethrow;
    } finally {
      _stepping = false;
      _currentCommands = const [];
    }
  }

  int advance(double seconds) {
    _requireOpen();
    if (!seconds.isFinite || seconds < 0) {
      throw ArgumentError('Elapsed seconds must be finite and nonnegative.');
    }
    if (_stepping) throw StateError('Session advance is not reentrant.');
    if (_paused) return 0;
    final due = clock.admit(seconds);
    var count = 0;
    for (; count < due && !_paused && !_closed;) {
      final previousTick = _tick;
      step();
      if (_tick == previousTick) break;
      count++;
    }
    return count;
  }

  /// Invalidates asynchronous decisions without changing the simulation tick.
  void invalidatePending() {
    _epoch++;
    commands.clear();
    _mutations.clear();
    clock.reset();
  }

  void pause() {
    _requireOpen();
    if (_paused) return;
    _paused = true;
    invalidatePending();
    try {
      for (final system in _started.reversed) {
        if (_closed || !_paused) break;
        if (!_removed.contains(system.id)) system.pause(this);
      }
      _notify();
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  void resume() {
    _requireOpen();
    if (!_paused) return;
    invalidatePending();
    _paused = false;
    try {
      for (final system in _started) {
        if (_closed || _paused) break;
        if (!_removed.contains(system.id)) system.resume(this);
      }
      _notify();
    } catch (error) {
      _fail(error);
      rethrow;
    }
  }

  void _fail(Object error) {
    _fault ??= error;
    _paused = true;
    invalidatePending();
    // Preserve the initiating failure while notifying every state observer.
    for (final id in _stateListeners.keys.toList()) {
      try {
        _stateListeners[id]?.call();
      } catch (_) {}
    }
  }

  Future<void> close() {
    if (_closing case final closing?) return closing;
    _closed = true;
    invalidatePending();
    // Defer cleanup until the current synchronous callback has returned.
    return _closing = Future<void>(() async {
      Object? firstError;
      StackTrace? firstStack;
      for (final system in _started.reversed) {
        try {
          await system.dispose(this);
        } catch (error, stack) {
          firstError ??= error;
          firstStack ??= stack;
        }
      }
      _started.clear();
      events.close();
      for (final entity in entities.entities) {
        entities.despawn(entity.handle);
      }
      try {
        _notify();
      } finally {
        _stateListeners.clear();
      }
      if (firstError != null) {
        Error.throwWithStackTrace(firstError, firstStack!);
      }
    });
  }
}
