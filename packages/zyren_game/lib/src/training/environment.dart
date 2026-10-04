part of '../../training.dart';

enum TrainingSplit { training, validation, test }

/// The host supplies the shared runtime and observation/action adapters.
final class GameTrainingInstance {
  final GameSession session;
  final void Function() step;
  final Future<void> Function() close;
  final Map<String, Float32List> Function() observe;
  final String observationSchemaHash, actionSchemaHash;
  final int actionWidth;
  final bool Function(Float32List) acceptAction;
  final Map<String, Object?> actionSpace;
  final bool supportsSnapshot;
  final Iterable<GameEntityHandle> Function() actors;
  final Future<void> Function()? beforeStep;
  final Future<void> Function()? afterStep;
  final void Function()? cancelPending;
  final double Function() reward;
  final bool Function() terminal, success;
  final Map<String, Object?> Function()? info;
  GameTrainingInstance({
    required this.session,
    required this.step,
    required this.close,
    required this.observe,
    required this.observationSchemaHash,
    required this.actionSchemaHash,
    required this.actionWidth,
    bool Function(Float32List)? acceptAction,
    Map<String, Object?>? actionSpace,
    this.supportsSnapshot = true,
    Iterable<GameEntityHandle> Function()? actors,
    this.beforeStep,
    this.afterStep,
    this.cancelPending,
    this.info,
    double Function()? reward,
    bool Function()? terminal,
    bool Function()? success,
  }) : acceptAction =
           acceptAction ?? ((v) => v.every((n) => n >= -1 && n <= 1)),
       actionSpace = _demoFreeze(
         actionSpace ??
             {
               'kind': 'box',
               'low': List.filled(actionWidth, -1.0),
               'high': List.filled(actionWidth, 1.0),
             },
       ),
       actors =
           actors ?? (() => session.entities.entities.map((e) => e.handle)),
       reward = reward ?? (() => 0),
       terminal = terminal ?? (() => false),
       success = success ?? (() => false) {
    _wireId(observationSchemaHash);
    _wireId(actionSchemaHash);
    _boundedInt(actionWidth, 4096, min: 1);
  }
  List<GameEntityHandle> get actorHandles {
    final result = <GameEntityHandle>[];
    final unique = <GameEntityHandle>{};
    for (final actor in actors()) {
      if (result.length >= 256 ||
          !unique.add(actor) ||
          !session.entities.isAlive(actor)) {
        throw StateError('Invalid controllable actors.');
      }
      _wireId(actor.id);
      result.add(actor);
    }
    if (result.isEmpty) throw StateError('Controllable actors are missing.');
    return List.unmodifiable(result);
  }
}

final class GameTrainingScenario {
  final String id;
  final TrainingSplit split;
  final int maxSteps;
  final Future<GameTrainingInstance> Function(int seed, String episodeId)
  create;
  GameTrainingScenario({
    required this.id,
    required this.split,
    required this.create,
    this.maxSteps = 10000,
  }) {
    _wireId(id);
    _boundedInt(maxSteps, 10000000, min: 1);
  }
}

final class GameTrainingResult {
  final Map<String, Object?> info;
  final Map<String, Float32List> observations;
  final double reward;
  final bool terminated, truncated;
  GameTrainingResult(
    this.info,
    this.observations,
    this.reward,
    this.terminated,
    this.truncated,
  );
}

/// One independent environment. Reset and step cannot overlap.
final class GameTrainingEnvironment {
  final String runId, environmentId;
  final Map<String, GameTrainingScenario> scenarios;
  final TrainingSplit purpose;
  GameTrainingInstance? _instance;
  GameTrainingScenario? _scenario;
  String _episodeId = 'uninitialized';
  int _episode = 0, _startTick = 0, _steps = 0;
  bool _busy = false, _closed = false, _ended = false, _failed = false;
  Completer<void>? _operationDone;
  Future<void>? _closeFuture;
  GameTrainingEnvironment({
    required this.runId,
    required this.environmentId,
    required Map<String, GameTrainingScenario> scenarios,
    this.purpose = TrainingSplit.training,
  }) : scenarios = Map.unmodifiable(scenarios) {
    _wireId(runId);
    _wireId(environmentId);
    if (scenarios.isEmpty ||
        scenarios.length > 256 ||
        scenarios.entries.any((e) => e.key != e.value.id)) {
      throw ArgumentError('Invalid training scenario catalog.');
    }
  }
  GameTrainingInstance? get instance => _instance;
  String get episodeId => _episodeId;
  bool get busy => _busy;
  Future<T> _exclusive<T>(Future<T> Function() run) async {
    if (_closed || _busy) throw StateError('Environment is closed or busy.');
    _busy = true;
    final done = Completer<void>();
    _operationDone = done;
    try {
      final result = await run();
      if (_closed) throw StateError('Environment closed during operation.');
      return result;
    } finally {
      _busy = false;
      _operationDone = null;
      done.complete();
    }
  }

  Future<GameTrainingResult> reset({
    required int seed,
    required String scenario,
  }) => _exclusive(() async {
    final definition = scenarios[scenario];
    if (definition == null || definition.split != purpose) {
      throw StateError('Scenario is missing or belongs to another data split.');
    }
    final nextEpisode = '$environmentId-${_episode + 1}';
    final candidate = await definition.create(seed, nextEpisode);
    try {
      if (candidate.session.seed != seed ||
          candidate.session.isClosed ||
          candidate.session.fault != null ||
          candidate.actorHandles.isEmpty) {
        throw StateError('Invalid prepared environment.');
      }
      await _instance?.close();
    } catch (_) {
      await candidate.close();
      rethrow;
    }
    _instance = candidate;
    _scenario = definition;
    _episode++;
    _episodeId = nextEpisode;
    _startTick = candidate.session.tick;
    _steps = 0;
    _ended = false;
    _failed = false;
    return _result();
  });
  Future<GameTrainingResult> step(
    Map<String, Float32List> actionByActor,
  ) => _exclusive(() async {
    final current = _instance;
    if (current == null || _ended || _failed) {
      throw StateError('Environment needs reset.');
    }
    final actors = current.actorHandles;
    if (actionByActor.length != actors.length ||
        actors.any((a) => !actionByActor.containsKey(a.id)) ||
        actionByActor.values.any(
          (v) =>
              v.length != current.actionWidth ||
              v.any((x) => !x.isFinite) ||
              !current.acceptAction(v),
        )) {
      throw ArgumentError('Invalid actor actions.');
    }
    if (current.session.commands.length + actors.length >
        current.session.commands.limits.maxQueuedCommands) {
      throw StateError('Command admission budget exceeded.');
    }
    final accepted = {
      for (final e in actionByActor.entries)
        e.key: Float32List.fromList(e.value),
    };
    final before = current.session.tick;
    // Await real inference before its due tick. This wait never advances the clock.
    await current.beforeStep?.call();
    if (_closed ||
        current.session.isClosed ||
        current.session.tick != before ||
        current.session.paused ||
        current.session.fault != null ||
        actors.any((a) => !current.session.entities.isAlive(a)) ||
        current.session.commands.length + actors.length >
            current.session.commands.limits.maxQueuedCommands) {
      throw StateError('Runtime changed while awaiting inference.');
    }
    for (final actor in actors) {
      if (!current.session.commands.enqueue(
        GameCommand(actor, before + 1, {
          'action': accepted[actor.id]!.toList(),
        }),
        current.session.entities,
      )) {
        _failed = true;
        throw StateError('Actor command was not accepted.');
      }
    }
    try {
      current.step();
      if (current.session.tick != before + 1) {
        throw StateError('Runtime did not advance one tick.');
      }
      await current.afterStep?.call();
      if (_closed ||
          current.session.isClosed ||
          current.session.tick != before + 1 ||
          current.session.paused ||
          current.session.fault != null) {
        throw StateError('Runtime changed while awaiting capture.');
      }
      _steps++;
      return _result();
    } catch (_) {
      _failed = true;
      rethrow;
    }
  });
  GameTrainingResult _result() {
    final current = _instance!, session = current.session;
    final observations = current.observe();
    final actorHandles = current.actorHandles;
    final actors = actorHandles.map((e) => e.id).toList();
    if (observations.length != actors.length ||
        actors.any((id) => !observations.containsKey(id)) ||
        observations.values.fold<int>(0, (sum, value) => sum + value.length) >
            trainingMaxMessage ~/ 4 ||
        observations.values.any(
          (v) => v.isEmpty || v.length > 1048576 || v.any((x) => !x.isFinite),
        )) {
      _failed = true;
      throw StateError('Invalid observation output.');
    }
    final value = current.reward();
    if (!value.isFinite) {
      _failed = true;
      throw StateError('Non-finite reward.');
    }
    final terminated = current.terminal(),
        truncated = !terminated && _steps >= _scenario!.maxSteps;
    _ended = terminated || truncated;
    return GameTrainingResult(
      {
        ...?current.info?.call(),
        'run_id': runId,
        'environment_id': environmentId,
        'episode_id': episodeId,
        'actor_ids': actors,
        'actor_generations': {for (final e in actorHandles) e.id: e.generation},
        'tick': session.tick,
        'seed': session.seed,
        'scenario': _scenario!.id,
        'split': _scenario!.split.name,
        'build_id': session.project.buildId,
        'observation_schema_hash': current.observationSchemaHash,
        'action_schema_hash': current.actionSchemaHash,
        'action_width': current.actionWidth,
        'action_space': current.actionSpace,
        'supports_snapshot': current.supportsSnapshot,
        'success': !_failed && terminated && current.success(),
        'worker_failed': false,
        'accepted_steps': _steps,
        'start_tick': _startTick,
      },
      {
        for (final e in observations.entries)
          e.key: Float32List.fromList(e.value),
      },
      value,
      terminated,
      truncated,
    );
  }

  Map<String, Object?> snapshot() {
    if (_closed ||
        _busy ||
        _instance == null ||
        _failed ||
        !_instance!.supportsSnapshot) {
      throw StateError('Environment cannot snapshot.');
    }
    return {
      'scenario': _scenario!.id,
      'episode_id': episodeId,
      'steps': _steps,
      'start_tick': _startTick,
      'ended': _ended,
      'save': _instance!.session.save().toJson(),
    };
  }

  Future<GameTrainingResult> restore(Map<String, Object?> snapshot) =>
      _exclusive(() async {
        if (_instance == null ||
            !_instance!.supportsSnapshot ||
            snapshot['scenario'] != _scenario!.id ||
            snapshot['episode_id'] != episodeId) {
          throw StateError('Snapshot environment identity differs.');
        }
        final steps = _boundedInt(snapshot['steps'], _scenario!.maxSteps),
            start = _boundedInt(snapshot['start_tick'], 9007199254740991);
        if (snapshot['ended'] is! bool) {
          throw const FormatException('Invalid episode end state.');
        }
        final save = GameSave.decode(jsonEncode(snapshot['save']));
        if (save.tick != start + steps) {
          throw const FormatException('Snapshot tick differs.');
        }
        _instance!.session.restore(save);
        _steps = steps;
        _startTick = start;
        _failed = false;
        _ended = snapshot['ended'] as bool;
        return _result();
      });
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closed = true;
    final failures = <Object>[];
    try {
      _instance?.cancelPending?.call();
    } catch (error) {
      failures.add(error);
    }
    await _operationDone?.future;
    try {
      await _instance?.close();
    } catch (error) {
      failures.add(error);
    } finally {
      _instance = null;
    }
    if (failures.isNotEmpty) {
      throw StateError('Environment cleanup failed: $failures');
    }
  }
}
