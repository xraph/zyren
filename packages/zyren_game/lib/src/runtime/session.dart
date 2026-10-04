part of '../../zyren_game.dart';

/// One simulation clock, shared by realtime play, replay and training.
final class GameSession {
  final CompiledGameProject project;
  final int seed;
  final String levelId;
  final GameClock clock;
  final GameEntityTable entities;
  final GameCommandQueue<Object> commands;
  final GameEventBus events;

  /// Measures the complete synchronous step before delivering this callback.
  /// No stopwatch is allocated when this observer is absent.
  final void Function(int tick, Duration elapsed)? onStepMeasured;

  /// Attributes each successful system update without replacing full-step timing.
  final void Function(String id, int tick, Duration elapsed)? onSystemMeasured;
  final List<GameSystem> _systems;
  final List<GameSystem> _started = [];
  final Set<String> _removed = {};
  final Queue<void Function(GameSession)> _mutations = Queue();
  final Map<int, void Function()> _stateListeners = {};
  final Map<String, GameStateCodec<Object>> _stateCodecs = {};
  bool _restoring = false;
  int _revision = 0;
  List<GameCommand<Object>> _currentCommands = const [];
  int _tick = 0, _epoch = 0, _listenerId = 0, _nextSystemStart = 0;
  bool _initialized = false,
      _stepping = false,
      _paused = false,
      _closed = false;
  Object? _fault;
  Future<void>? _closing;
  GameRealtimeClock? _realtimeClock;
  bool _manualStepping = false;
  GameRealtimeClock? get realtimeClock => _realtimeClock;
  GameSession({
    required this.project,
    required this.seed,
    String? levelId,
    int? fixedHz,
    int maxCatchUpSteps = 8,
    List<GameSystem> systems = const [],
    this.onStepMeasured,
    this.onSystemMeasured,
  }) : levelId = levelId ?? project.project.startupLevel,
       clock = GameClock(
         fixedHz: fixedHz ?? project.fixedHz,
         maxCatchUpSteps: maxCatchUpSteps,
       ),
       entities = GameEntityTable(limits: project.project.registry.limits),
       commands = GameCommandQueue(limits: project.project.registry.limits),
       events = GameEventBus(),
       _systems = _orderSystems(systems) {
    if (!project.levels.any((l) => l.id == this.levelId)) {
      throw StateError('Session level is missing.');
    }
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
  int get revision => _revision;
  int get epoch => _epoch;
  int get fixedHz => clock.fixedHz;
  double get stepSeconds => clock.stepSeconds;
  double get droppedSeconds => clock.droppedSeconds;
  bool get paused => _paused;
  bool get isClosed => _closed;
  bool get isStepping => _stepping;
  bool get isRestoring => _restoring;
  Object? get fault => _fault;
  List<GameCommand<Object>> get currentCommands => _currentCommands;

  /// Cancels this actor's due and future commands without invalidating others.
  int cancelCommands(GameEntityHandle actor) {
    _requireOpen();
    if (_restoring) throw StateError('Session is staging a restore.');
    final queued = commands.cancelTarget(actor),
        before = _currentCommands.length;
    _currentCommands = List.unmodifiable(
      _currentCommands.where((command) => command.target != actor),
    );
    return queued + before - _currentCommands.length;
  }

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
    _revision++;
    for (final id in _stateListeners.keys.toList()) {
      _stateListeners[id]?.call();
    }
  }

  void _requireOpen() {
    if (_restoring) throw StateError('Session is staging a restore.');
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
      final level = project.levels.singleWhere((l) => l.id == levelId);
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
    if (_realtimeClock?.running == true) {
      throw StateError('The realtime clock owns simulation stepping.');
    }
    _step();
  }

  /// Advances exactly once from an explicit pause, then restores that pause.
  void stepOnce({void Function()? onResume}) {
    _requireOpen();
    if (!_paused || _stepping || _manualStepping) {
      throw StateError('Pause before single stepping.');
    }
    _manualStepping = true;
    try {
      resume();
      onResume?.call();
      _step();
    } finally {
      try {
        if (!_closed && _fault == null) pause();
      } finally {
        _manualStepping = false;
      }
    }
  }

  void _step() {
    _requireOpen();
    if (_stepping) throw StateError('Session step is not reentrant.');
    if (_paused) return;
    _stepping = true;
    final measurement = onStepMeasured == null ? null : (Stopwatch()..start());
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
        if (!_removed.contains(system.id)) {
          final measurement = onSystemMeasured == null
              ? null
              : (Stopwatch()..start());
          system.fixedUpdate(this);
          if (measurement != null) {
            measurement.stop();
            onSystemMeasured!(system.id, _tick, measurement.elapsed);
          }
        }
      }
      _notify();
      if (measurement != null) {
        measurement.stop();
        onStepMeasured!(_tick, measurement.elapsed);
      }
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
    if (_realtimeClock != null) {
      throw StateError('The realtime clock owns elapsed-time admission.');
    }
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
    if (_restoring) throw StateError('Session is staging a restore.');
    _revision++;
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
    if (_restoring) throw StateError('Session is staging a restore.');
    if (_closing case final closing?) return closing;
    _closed = true;
    _realtimeClock?.dispose();
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
      _stateCodecs.clear();
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

  GameEventSubscription registerStateCodec(GameStateCodec<Object> codec) {
    _requireOpen();
    _id(codec.id);
    if (codec.version < 1 ||
        _stateCodecs.containsKey(codec.id) ||
        _stateCodecs.length >= 256) {
      throw StateError('Invalid or duplicate runtime state codec.');
    }
    _stateCodecs[codec.id] = codec;
    return GameEventSubscription._(() {
      if (_restoring) throw StateError('Cannot unregister during restore.');
      if (identical(_stateCodecs[codec.id], codec)) {
        _stateCodecs.remove(codec.id);
      }
    });
  }

  GameSave save() {
    _requireOpen();
    if (_stepping) throw StateError('Save requires a tick boundary.');
    final authored = project.levels
        .singleWhere((l) => l.id == levelId)
        .entities;
    return GameSave(
      projectId: project.id,
      buildId: project.buildId,
      levelId: levelId,
      projectSchema: project.project.schemaVersion,
      seed: seed,
      tick: tick,
      paused: paused,
      entities: _initialized
          ? entities.entities
                .map(
                  (e) => GameEntityRecord(
                    id: e.handle.id,
                    nodeId: authored
                        .where((a) => a.id == e.handle.id)
                        .firstOrNull
                        ?.nodeId,
                    components: e.components,
                  ),
                )
                .toList()
          : authored,
      models: project.project.modelReferences,
      state: {
        for (final codec in _stateCodecs.values) codec.id: codec.capture(this),
      },
      codecVersions: {
        for (final codec in _stateCodecs.values) codec.id: codec.version,
      },
    );
  }

  /// Prepare all replacements and rollback stages before committing live state.
  void restore(GameSave save) {
    _requireOpen();
    if (_stepping) throw StateError('Restore requires a tick boundary.');
    if (save.projectId != project.id ||
        save.buildId != project.buildId ||
        save.levelId != levelId ||
        save.projectSchema != project.project.schemaVersion ||
        save.seed != seed ||
        jsonEncode(_canonicalGameJson(save.models)) !=
            jsonEncode(_canonicalGameJson(project.project.modelReferences)) ||
        save.codecVersions.length != _stateCodecs.length ||
        save.codecVersions.entries.any(
          (e) => _stateCodecs[e.key]?.version != e.value,
        )) {
      throw StateError('Save identity or required runtime codecs differ.');
    }
    final records = _validateEntities(save.entities, project.project.registry);
    if (records.any(
      (e) => e.components.any(
        (c) => c.required && !project.project.registry.supports(c),
      ),
    )) {
      throw StateError('Save requires missing components.');
    }
    final beforeEntities = Map<String, GameRuntimeEntity>.of(
      entities._entities,
    );
    final beforeGenerations = Map<String, int>.of(entities._generations);
    final beforeHighWater = entities._highWater;
    final checkpoint = (
      tick: _tick,
      epoch: _epoch,
      paused: _paused,
      initialized: _initialized,
      accumulator: clock._accumulator,
      pendingSteps: clock._pendingSteps,
      dropped: clock.droppedSeconds,
      lastTick: commands._lastTick,
    );
    final beforeCommands = commands._commands.toList(),
        beforeMutations = _mutations.toList();
    final replacement = GameEntityTable(limits: entities.limits);
    replacement._generations.addAll(beforeGenerations);
    replacement._highWater = beforeHighWater;
    for (final record in records) {
      replacement.spawn(record.id, components: record.components);
    }
    final originals = <String, Object>{}, candidates = <String, Object>{};
    final committed = <String>[];
    _restoring = true;
    void recoverRuntime() {
      entities._entities
        ..clear()
        ..addAll(beforeEntities);
      entities._generations
        ..clear()
        ..addAll(beforeGenerations);
      entities._highWater = beforeHighWater;
      _tick = checkpoint.tick;
      _epoch = checkpoint.epoch;
      _paused = checkpoint.paused;
      _initialized = checkpoint.initialized;
      clock._accumulator = checkpoint.accumulator;
      clock._pendingSteps = checkpoint.pendingSteps;
      clock.droppedSeconds = checkpoint.dropped;
      commands._commands
        ..clear()
        ..addAll(beforeCommands);
      commands._lastTick = checkpoint.lastTick;
      _mutations
        ..clear()
        ..addAll(beforeMutations);
    }

    Object? rollbackFailure;
    try {
      for (final codec in _stateCodecs.values) {
        originals[codec.id] = codec.prepare(this, _json(codec.capture(this)));
        candidates[codec.id] = codec.prepare(this, _map(save.state[codec.id]));
      }
      entities._entities
        ..clear()
        ..addAll(replacement._entities);
      entities._generations
        ..clear()
        ..addAll(replacement._generations);
      entities._highWater = replacement._highWater;
      _tick = save.tick;
      _epoch++;
      _paused = save.paused;
      _initialized = true;
      clock.reset();
      commands.clear();
      commands._lastTick = save.tick;
      _mutations.clear();
      for (final codec in _stateCodecs.values) {
        committed.add(codec.id); // A failing commit may have partially mutated.
        codec.commit(this, candidates[codec.id]!);
      }
    } catch (error, stack) {
      recoverRuntime();
      for (final id in committed.reversed) {
        try {
          _stateCodecs[id]!.commit(this, originals[id]!);
          originals.remove(id);
        } catch (e) {
          rollbackFailure ??= e;
        }
      }
      for (final entry in candidates.entries) {
        try {
          _stateCodecs[entry.key]!.discard(entry.value);
        } catch (e) {
          rollbackFailure ??= e;
        }
      }
      _restoring = false;
      if (rollbackFailure != null) {
        _fail(StateError('Restore rollback failed: $rollbackFailure'));
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      for (final entry in originals.entries) {
        try {
          _stateCodecs[entry.key]!.discard(entry.value);
        } catch (e) {
          rollbackFailure ??= e;
        }
      }
      _restoring = false;
      if (rollbackFailure != null && _fault == null) {
        _fail(StateError('Restore staging cleanup failed: $rollbackFailure'));
      }
    }
    if (rollbackFailure != null) {
      _fail(StateError('Restore staging cleanup failed: $rollbackFailure'));
      throw StateError('Restore staging cleanup failed.');
    }
    _notify();
  }
}
