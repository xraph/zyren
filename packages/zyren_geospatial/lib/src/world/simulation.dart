import 'dart:async';
import 'package:zyren/zyren.dart';
import 'time.dart';

enum GeoSimulationPhase { sample, forces, integrate, interact, publish }

abstract class GeoSimulationSystem {
  String get id;
  Set<String> get dependencies => const {};
  GeoSimulationPhase get phase => GeoSimulationPhase.integrate;
  bool get supportsReplay => false;
  bool get supportsInterpolation => false;
  int? get requiredHz => null;
  int get maxCatchUpSteps => 8;
  FutureOr<void> step(GeoInstant instant);
  FutureOr<void> restore(GeoInstant checkpoint) =>
      throw UnsupportedError('System $id does not support replay restoration.');
}

final class GeoSimulationFailure implements Exception {
  final GeoInstant instant;
  final String systemId;
  final Object cause;
  final List<String> completedSystemIds;
  GeoSimulationFailure(
    this.instant,
    this.systemId,
    this.cause,
    Iterable<String> completed,
  ) : completedSystemIds = List.unmodifiable(completed);
  @override
  String toString() =>
      'Simulation step ${instant.tick} failed in $systemId: $cause';
}

/// One leased system graph. Failures retain partial-step evidence across leases.
final class GeoSimulation {
  static final _owners = Expando<Object>('GeoSimulationSystem owner');
  final List<GeoSimulationSystem> systems;
  Object? _owner;
  GeoInstant? _last;
  GeoSimulationFailure? _failure;
  GeoSimulation({
    required List<GeoSimulationSystem> systems,
    GeoInstant? initialInstant,
  }) : systems = _resolve(systems),
       _last = initialInstant;
  GeoInstant? get lastCompleted => _last;
  GeoSimulationFailure? get failure => _failure;
  GeoSimulationDriver acquireDriver(String owner) {
    if (owner.trim().isEmpty || _owner != null) {
      throw StateError('Simulation driver owner is missing or already leased.');
    }
    for (final system in systems) {
      if (_owners[system] != null) {
        throw StateError('System ${system.id} belongs to another driver.');
      }
    }
    final token = _owner = Object();
    for (final system in systems) {
      _owners[system] = token;
    }
    return GeoSimulationDriver._(this, token, owner);
  }

  static List<GeoSimulationSystem> _resolve(List<GeoSimulationSystem> input) {
    if (input.length > 1024) {
      throw ArgumentError('A simulation supports at most 1024 systems.');
    }
    final byId = <String, GeoSimulationSystem>{};
    for (final system in input) {
      if (system.id.trim().isEmpty || byId.containsKey(system.id)) {
        throw ArgumentError('Simulation IDs must be nonempty and unique.');
      }
      if (system.maxCatchUpSteps < 1 ||
          system.maxCatchUpSteps > 10000 ||
          (system.requiredHz != null &&
              (system.requiredHz! < 1 || system.requiredHz! > 1000000))) {
        throw ArgumentError('Invalid system rate or catchup limit.');
      }
      byId[system.id] = system;
    }
    final ordered = <GeoSimulationSystem>[],
        active = <String>{},
        done = <String>{};
    void visit(GeoSimulationSystem system) {
      if (done.contains(system.id)) return;
      if (!active.add(system.id)) {
        throw ArgumentError('Simulation dependency cycle at ${system.id}.');
      }
      final dependencies = system.dependencies.toList()..sort();
      for (final id in dependencies) {
        final dependency = byId[id];
        if (dependency == null || dependency.phase.index > system.phase.index) {
          throw ArgumentError('Missing or later-phase dependency $id.');
        }
        visit(dependency);
      }
      active.remove(system.id);
      done.add(system.id);
      ordered.add(system);
    }

    final sorted = input.toList()
      ..sort((a, b) {
        final phase = a.phase.index.compareTo(b.phase.index);
        return phase == 0 ? a.id.compareTo(b.id) : phase;
      });
    for (final system in sorted) {
      visit(system);
    }
    return List.unmodifiable(ordered);
  }
}

final class GeoSimulationDriver extends Registration {
  final GeoSimulation _simulation;
  final Object _token;
  final String owner;
  final _closed = Completer<void>();
  bool _busy = false, _closing = false;
  GeoSimulationDriver._(this._simulation, this._token, this.owner)
    : super(() {}) {
    // Disposal is overridden so ownership is held while an async step drains.
  }
  Future<void> get whenClosed => _closed.future;
  GeoSimulationFailure? get failure => _simulation.failure;
  void _check() {
    if (_closing || !identical(_simulation._owner, _token)) {
      throw StateError('Simulation driver has closed.');
    }
    if (_busy) throw StateError('Simulation steps cannot overlap.');
  }

  Future<void> step(GeoInstant instant) async {
    _check();
    _busy = true;
    try {
      await _run(instant);
    } finally {
      _busy = false;
      _finishClose();
    }
  }

  Future<int> advance(GeoClockDriver clock, Duration elapsed) async {
    _check();
    if (_simulation.failure != null) {
      throw StateError('Restore the failed simulation before advancing.');
    }
    _validateNext(clock.instant.withTick(clock.instant.tick + 1));
    final advancement = clock.beginAdvance();
    _busy = true;
    try {
      final maxSteps = _simulation.systems.fold<int>(
        10000,
        (limit, system) =>
            system.maxCatchUpSteps < limit ? system.maxCatchUpSteps : limit,
      );
      final count = advancement.admit(elapsed, maxSteps: maxSteps);
      for (var i = 0; i < count; i++) {
        if (_closing) {
          throw StateError('Simulation driver closed during advancement.');
        }
        advancement.step();
        await _run(advancement.instant);
      }
      return count;
    } finally {
      advancement.dispose();
      _busy = false;
      _finishClose();
    }
  }

  Future<void> _run(GeoInstant instant) async {
    if (_simulation.failure != null) {
      throw StateError('Restore the failed simulation before stepping.');
    }
    _validateNext(instant);
    final completed = <String>[];
    for (final system in _simulation.systems) {
      try {
        if (_closing) {
          throw StateError('Simulation driver closed during a step.');
        }
        await system.step(instant);
        completed.add(system.id);
      } catch (error, stack) {
        final failure = _simulation._failure = GeoSimulationFailure(
          instant,
          system.id,
          error,
          completed,
        );
        Error.throwWithStackTrace(failure, stack);
      }
    }
    _simulation._last = instant;
  }

  void _validateNext(GeoInstant instant) {
    final previous = _simulation._last;
    if ((previous == null && instant.tick != 1) ||
        (previous != null &&
            (!instant.sameTimeline(previous) ||
                instant.tick != previous.tick + 1))) {
      throw StateError(
        'Simulation ticks must follow the initialized state on the current generation.',
      );
    }
    if (_simulation.systems.any(
      (system) => system.requiredHz != null && system.requiredHz != instant.hz,
    )) {
      throw ArgumentError(
        'Simulation tick rate does not match a required system rate.',
      );
    }
  }

  Future<void> beginReplay(GeoInstant checkpoint) async {
    _check();
    final previous = _simulation.failure?.instant ?? _simulation._last;
    if (previous != null &&
        (checkpoint.generation <= previous.generation ||
            checkpoint.hz != previous.hz ||
            checkpoint.epoch != previous.epoch ||
            checkpoint.standard != previous.standard)) {
      throw ArgumentError(
        'Replay requires the same time standard and a new generation.',
      );
    }
    if (_simulation.systems.any((system) => !system.supportsReplay)) {
      throw UnsupportedError(
        'Every stateful system must support checkpoint restoration.',
      );
    }
    _busy = true;
    final completed = <String>[];
    try {
      for (final system in _simulation.systems) {
        try {
          if (_closing) {
            throw StateError('Replay driver closed during restoration.');
          }
          await system.restore(checkpoint);
          completed.add(system.id);
        } catch (error, stack) {
          final failure = _simulation._failure = GeoSimulationFailure(
            checkpoint,
            system.id,
            error,
            completed,
          );
          Error.throwWithStackTrace(failure, stack);
        }
      }
      _simulation._last = checkpoint;
      _simulation._failure = null;
    } finally {
      _busy = false;
      _finishClose();
    }
  }

  @override
  void dispose() {
    if (_closing) return;
    _closing = true;
    super.dispose();
    _finishClose();
  }

  void _finishClose() {
    if (!_closing || _busy || _closed.isCompleted) return;
    for (final system in _simulation.systems) {
      if (identical(GeoSimulation._owners[system], _token)) {
        GeoSimulation._owners[system] = null;
      }
    }
    if (identical(_simulation._owner, _token)) _simulation._owner = null;
    _closed.complete();
  }
}
