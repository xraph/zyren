/// Authored AI actors bound to the shared native game runtime.
library;

import 'dart:async';
import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'zyren_game_ai.dart';
part 'src/runtime/checkpoint.dart';
part 'src/runtime/visual.dart';

/// The host resolves this only after validating the training acceptance receipt.
final class GameRuntimePolicy {
  final PolicyContract contract;
  final int fixedHz;
  final String evaluationHash;
  GameRuntimePolicy({
    required this.contract,
    required this.fixedHz,
    required this.evaluationHash,
  }) {
    if (fixedHz < 10 ||
        fixedHz > 240 ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(evaluationHash)) {
      throw ArgumentError(
        'A runtime policy needs its evaluated timing and receipt pin.',
      );
    }
  }
}

/// Owns actor brains and the scheduler. The scheduler drains and closes [cache].
/// Scene, physics and controller lifetimes remain with [runtime].
final class GameLevelAi {
  final GameLevelRuntime Function() runtime;
  final MlModelCache cache;
  final Map<String, GameRuntimePolicy> policies;
  final void Function()? onChanged;
  final bool Function(GameEntityHandle actor)? interact;
  final Future<RenderBackend> Function(
    GameEntityHandle actor,
    TrainingVisualProfile profile,
  )?
  openCameraBackend;
  final GameVisualRuntimeLimits visualLimits;
  final _cameraJobs = <Future<void>>{};
  int _cameraBytes = 0;
  int _cameraOwners = 0;
  int get pendingCameraCaptures => _cameraJobs.length;
  int get reservedCameraOutputBytes => _cameraBytes;
  int get ownedCameraSensors => _cameraOwners;
  final _actors = <GameEntityHandle, _RuntimeBrain>{};
  final _leases = <MlModelLease>[];
  final _loadedModels = <String>{};
  final _modelLoadFailures = <String, String>{};
  final _sounds = <GameSoundEvent>[];
  final _policyFailures = <String, String>{};
  final _retiring = <Future<void>>{};
  MlScheduler? _scheduler;
  PolicyGroup? _group;
  PolicyGroup? get group => _group;
  GameSession? _session;
  GameEventSubscription? _events, _codec;
  _AiCheckpoint? _preparedCheckpoint;
  Object? _retirementError;
  StackTrace? _retirementTrace;
  Registration? _restored, _topology, _spawnValidator;
  bool _warmed = false, _closed = false;
  Future<void>? _closing, _warming;
  int _identity = 0;
  int completedDecisions = 0, fallbackTicks = 0, scriptedTicks = 0;
  GameLevelAi({
    required this.runtime,
    required this.cache,
    Map<String, GameRuntimePolicy> policies = const {},
    this.onChanged,
    this.interact,
    this.openCameraBackend,
    this.visualLimits = const GameVisualRuntimeLimits(),
  }) : policies = Map.unmodifiable(policies) {
    visualLimits.validate();
    if (policies.length > 8 ||
        policies.entries.any(
          (entry) => entry.key != entry.value.contract.model.sha256,
        )) {
      throw ArgumentError(
        'Policy catalog must contain at most eight pinned models.',
      );
    }
  }

  List<GameEntityHandle> get actors => List.unmodifiable(_actors.keys);
  Map<GameEntityHandle, SensorProfile> get sensorProfiles => Map.unmodifiable({
    for (final entry in _actors.entries)
      entry.key: entry.value.observer.profile,
  });
  List<GameSystem> get systems => [_AiDecisions(this), _AiSensors(this)];

  /// Preflight and load all authored models before attaching the native scene.
  Future<void> warmup() {
    if (_closed || _warming != null) {
      throw StateError('AI owner is closed or already prepared.');
    }
    return _warming = _warmup();
  }

  Future<void> _warmup() async {
    final level = runtime().project.project.levels.singleWhere(
      (level) => level.id == runtime().project.project.startupLevel,
    );
    var count = 0, visualCount = 0;
    final used = <String>{}, required = <String>{};
    for (final entity in level.entities) {
      final records = entity.components.where((c) => c.type == 'game.ai');
      if (records.isEmpty) continue;
      if (++count > 256) {
        throw StateError('This policy group supports at most 256 actors.');
      }
      final definition = GameAiAuthoringDefinition(records.single.data);
      if (definition.multiTask != null) {
        throw UnsupportedError('Multi-agent runtime integration is pending.');
      }
      if (definition.visualProfile != null &&
          ++visualCount > visualLimits.maxActors) {
        throw StateError(
          'Visual actor admission exceeds the configured bound.',
        );
      }
      final component = definition.profile == 'guard'
          ? 'game.character'
          : 'game.vehicle';
      if (!entity.components.any((c) => c.type == component)) {
        throw StateError(
          '${entity.id} needs a $component controller for its AI profile.',
        );
      }
      if (definition.brain == 'scripted') continue;
      final policy = policies[definition.modelHash];
      if (policy == null ||
          policy.fixedHz != runtime().project.fixedHz ||
          policy.contract.observation.hash != definition.observationSpec.hash ||
          policy.contract.decoder.spec.hash !=
              definition.createActions().spec.hash) {
        if (definition.brain == 'hybrid') {
          _policyFailures[entity.id] =
              'No compatible evaluated policy at this simulation rate.';
          continue;
        }
        throw StateError(
          '${entity.id} has no compatible evaluated policy at this simulation rate.',
        );
      }
      used.add(definition.modelHash!);
      if (definition.brain == 'learned') required.add(definition.modelHash!);
    }
    // A prepared spawn can use any registered model without loading native
    // weights inside a simulation tick. Required actors still fail closed.
    used.addAll(policies.keys);
    try {
      for (final hash in used) {
        try {
          final lease = await cache.acquire(policies[hash]!.contract.model);
          if (_closed) {
            await cache.release(lease);
            throw StateError('AI owner closed during model preparation.');
          }
          _leases.add(lease);
          _loadedModels.add(hash);
        } catch (error) {
          if (_closed || required.contains(hash)) rethrow;
          _modelLoadFailures[hash] = '$error'.substring(
            0,
            '$error'.length.clamp(0, 512),
          );
          for (final entity in level.entities) {
            final record = entity.components
                .where((c) => c.type == 'game.ai')
                .firstOrNull;
            if (record != null && record.data['modelHash'] == hash) {
              _policyFailures[entity.id] = '$error'.substring(
                0,
                '$error'.length.clamp(0, 512),
              );
            }
          }
        }
      }
      _warmed = true;
    } catch (_) {
      for (final lease in _leases) {
        await cache.release(lease);
      }
      _leases.clear();
      rethrow;
    }
  }

  void _start(GameSession session) {
    if (!_warmed || _closed || _session != null) {
      throw StateError('Prepare the AI owner once before running its session.');
    }
    _session = session;
    _scheduler = MlScheduler(
      cache: cache,
      currentTick: () => session.tick,
      maxQueuedRequests: 256,
      // The sensors phase submits its actor cohort synchronously. Dispatch on
      // the next event turn without adding the generic ingress batching delay.
      batchWait: Duration.zero,
    );
    _events = session.events.listen((event) {
      if (event.payload case final GameSoundEvent sound) {
        if (_sounds.length == 128) _sounds.removeAt(0);
        _sounds.add(sound);
      }
    });
    _bind();
    _spawnValidator = runtime().registerSpawnValidator(_validateSpawn);
    _topology = runtime().listenTopology(_changeTopology);
    _codec = session.registerStateCodec(_AiCodec(this));
    _restored = runtime().listenRestored(() {
      final checkpoint = _preparedCheckpoint;
      if (checkpoint == null) throw StateError('AI checkpoint is missing.');
      _bind();
      _applyCheckpoint(checkpoint);
      _preparedCheckpoint = null;
    });
  }

  void _retire(Future<void> future) {
    _retiring.add(future);
    future.then<void>(
      (_) => _retiring.remove(future),
      onError: (Object error, StackTrace trace) {
        _retirementError ??= error;
        _retirementTrace ??= trace;
        _retiring.remove(future);
      },
    );
  }

  void _bind() {
    final session = _session!;
    if (_retiring.length >= 8) {
      throw StateError('Wait for AI cleanup before another restore.');
    }
    final previous = _group;
    final retiring = _actors.values.toList();
    _actors.clear();
    if (previous != null) _retire(_closeBrains(retiring, previous));
    final episode = 'runtime-${++_identity}';
    _group = PolicyGroup(
      episodeId: episode,
      entities: session.entities,
      ml: _scheduler!,
      maxActors: 256,
    );
    for (final entity in session.entities.entities) {
      _bindActor(entity);
    }
    _sounds.clear();
    onChanged?.call();
  }

  void _bindActor(GameRuntimeEntity entity) {
    final session = _session!, group = _group!;
    final record = entity.components
        .where((c) => c.type == 'game.ai')
        .firstOrNull;
    if (record == null) return;
    final definition = _validateDefinition(
      entity.handle.id,
      entity.components,
      remember: true,
    );
    final identity = BrainIdentity(
      episodeId: group.episodeId,
      entity: entity.handle,
      modelHash: definition.modelHash ?? 'scripted-${definition.profile}',
    );
    final observer = definition.createSensors();
    final awareness = ObservationAssembler(
      registry: SensorRegistry()
        ..register(
          BodySensor(maxSpeed: definition.profile == 'guard' ? 10 : 30),
        )
        ..register(VisionSensor(observer.profile))
        ..register(HearingSensor(observer.profile, maxSounds: 4)),
      profile: observer.profile,
    );
    final scripted = ScriptedBrain(
      identity: identity,
      entities: session.entities,
      driver: definition.profile == 'vehicle',
    );
    PolicyBrain? policy;
    if (definition.brain != 'scripted' &&
        !_policyFailures.containsKey(entity.handle.id)) {
      policy = group.join(
        identity,
        policies[definition.modelHash]!.contract,
        autoRequest: false,
      );
    }
    final GameBrain brain;
    if (policy == null) {
      brain = scripted;
    } else if (definition.brain == 'learned') {
      brain = policy;
    } else {
      brain = HybridBrain(
        identity: identity,
        selector: UtilityGoalSelector(minCommitmentTicks: 1),
        skills: {'learned': policy, 'scripted': _BaselineSkill(scripted)},
        actionSpecs: {
          'learned': policy.contract.decoder.spec,
          'scripted': scripted.actionSpec,
        },
      );
    }
    _actors[entity.handle] = _RuntimeBrain(
      identity,
      definition,
      observer,
      awareness,
      brain,
      scripted,
      policy,
    );
    final visual = definition.visualProfile;
    if (visual != null) {
      _actors[entity.handle]!.camera = _RuntimeCamera(
        visual,
        () => _openCameraSensor(entity.handle, visual),
        () => _cameraOwners--,
      );
    }
  }

  GameAiAuthoringDefinition _validateDefinition(
    String id,
    List<GameComponentRecord> components, {
    bool remember = false,
  }) {
    final record = components.singleWhere((c) => c.type == 'game.ai');
    final definition = GameAiAuthoringDefinition(record.data);
    if (definition.multiTask != null) {
      throw UnsupportedError('Multi-agent runtime integration is pending.');
    }
    final controller = definition.profile == 'guard'
        ? 'game.character'
        : 'game.vehicle';
    if (!components.any((c) => c.type == controller)) {
      throw StateError('$id needs a $controller controller.');
    }
    if (remember) _policyFailures.remove(id);
    if (definition.brain == 'scripted') return definition;
    final policy = policies[definition.modelHash];
    final valid =
        policy != null &&
        policy.fixedHz == runtime().project.fixedHz &&
        policy.contract.observation.hash == definition.observationSpec.hash &&
        policy.contract.decoder.spec.hash ==
            definition.createActions().spec.hash &&
        _loadedModels.contains(definition.modelHash);
    if (!valid) {
      if (definition.brain == 'learned') {
        throw StateError('$id needs a prepared compatible evaluated policy.');
      }
      if (remember) {
        _policyFailures[id] =
            _modelLoadFailures[definition.modelHash] ??
            'No compatible evaluated policy at this simulation rate.';
      }
    }
    return definition;
  }

  void _validateSpawn(List<GameEntityRecord> records) {
    if (_closed || _retiring.length >= 8 || _retirementError != null) {
      throw StateError('Wait for AI cleanup before changing topology.');
    }
    final additions = records.where(
      (e) => e.components.any((c) => c.type == 'game.ai'),
    );
    final existing = _actors.keys.map((h) => h.id).toSet();
    if ({...existing, ...additions.map((e) => e.id)}.length > 256) {
      throw StateError('This policy group supports at most 256 actors.');
    }
    final visualIds = {
      for (final actor in _actors.values)
        if (actor.camera != null) actor.identity.entity.id,
      for (final record in additions)
        if (GameAiAuthoringDefinition(
              record.components.singleWhere((c) => c.type == 'game.ai').data,
            ).visualProfile !=
            null)
          record.id,
    };
    if (visualIds.length > visualLimits.maxActors) {
      throw StateError('Visual actor admission exceeds the configured bound.');
    }
    for (final record in additions) {
      _validateDefinition(record.id, record.components);
    }
  }

  void _changeTopology(GameRuntimeTopologyChange change) {
    if (_closed) return;
    final retired = <_RuntimeBrain>[];
    final leaving = <Future<void>>[];
    for (final handle in change.removed) {
      final actor = _actors.remove(handle);
      if (actor == null) continue;
      actor.control?.dispose();
      retired.add(actor);
      leaving.add(_group!.leave(handle));
      _policyFailures.remove(handle.id);
    }
    if (retired.isNotEmpty) {
      _retire(Future.wait<void>([_closeBrains(retired, null), ...leaving]));
    }
    for (final handle in change.added) {
      final entity = _session!.entities.entities.singleWhere(
        (e) => e.handle == handle,
      );
      _bindActor(entity);
    }
    onChanged?.call();
  }

  BrainContext _context(_RuntimeBrain actor, {required bool scripted}) {
    final session = _session!,
        memory = actor.scripted.memory.atTick(session.tick);
    final frame = actor.frame;
    final targets = <GameEntityHandle>{
      for (final entity in frame?.entities ?? <ObservedEntity?>[])
        if (entity != null && session.entities.isAlive(entity.handle))
          entity.handle,
      for (final belief in memory)
        if (belief.target != null && session.entities.isAlive(belief.target!))
          belief.target!,
    };
    final spec = scripted
        ? actor.scripted.actionSpec
        : actor.definition.createActions().spec;
    final valid =
        frame != null &&
        frame.readings.every(
          (reading) =>
              reading.state == SensorState.known ||
              // Hidden or unadmitted targets keep their validity bits clear.
              // This is a trained observation, not a broken sensor.
              reading.sensorId == 'vision' &&
                  reading.state == SensorState.unknown &&
                  reading.reason == 'partial-catalog-coverage',
        );
    return BrainContext(
      identity: actor.identity,
      tick: session.tick,
      gameEpoch: session.epoch,
      controlEpoch: actor.control?.generation ?? 0,
      observation: frame,
      beliefs: memory,
      goals: actor.brain is HybridBrain
          ? [
              GameGoal(
                id: valid ? 'policy' : 'baseline',
                skill: valid ? 'learned' : 'scripted',
              ),
            ]
          : [],
      validTargets: targets,
      actionSpec: spec,
      legality: spec.branches.isEmpty
          ? null
          : [
              for (final branch in spec.branches)
                [
                  for (var i = 0; i < branch.choices.length; i++)
                    branch.name == 'jump' && i == 1
                        ? runtime().actorGrounded(actor.identity.entity) == true
                        : branch.name == 'interact' && i == 1
                        ? interact != null
                        : true,
                ],
            ],
    );
  }

  void _decide(GameSession session) {
    for (final entry in _actors.entries) {
      final actor = entry.value;
      if (!session.entities.isAlive(entry.key)) continue;
      if (actor.control?.isActive != true) {
        actor.control?.dispose();
        actor.control = runtime().acquireActorControl(entry.key);
      }
      final policy = actor.policy;
      policy?.synchronize(
        gameEpoch: session.epoch,
        controlEpoch: actor.control?.generation ?? 0,
        paused: actor.control == null,
        preserveCommittedState:
            actor.suspended &&
            runtime().controlledActor != entry.key &&
            runtime().inputActor != entry.key,
      );
      if (runtime().controlledActor == entry.key ||
          runtime().inputActor == entry.key) {
        actor.suspended = false;
        actor.camera?.invalidate();
      }
      if (actor.control == null) continue;
      actor.suspended = false;
      if (actor.frame == null) continue;
      final context = _context(actor, scripted: actor.policy == null);
      final decision = actor.brain.decide(context);
      if (!decision.isApplicable(session.entities, actor.identity)) continue;
      if (decision.policyAction != null) {
        final decoded = actor.definition.createActions().decode(
          decision.policyAction!,
          legality: context.legality,
        );
        if (decoded == null) {
          throw StateError('Policy action failed controller validation.');
        }
        if (decoded.character case final intent?) {
          actor.control!.applyCharacter(intent);
          if (intent.interact) interact?.call(entry.key);
        }
        if (decoded.vehicle case final intent?) {
          actor.control!.applyVehicle(intent);
        }
        if (decision.isFallback) {
          fallbackTicks++;
        } else if (actor.policy!.state.version > actor.lastCountedVersion) {
          completedDecisions++;
          actor.lastCountedVersion = actor.policy!.state.version;
        }
      } else {
        scriptedTicks++;
        if (actor.definition.brain != 'scripted') fallbackTicks++;
        _scriptedAction(actor, decision);
      }
    }
  }

  void _scriptedAction(_RuntimeBrain actor, BrainDecision decision) {
    var character = const CharacterIntent();
    var vehicle = const VehicleIntent(brake: 1);
    for (final command in decision.actions) {
      final values = command.arguments;
      switch (command.action) {
        case 'ai.move':
          character = CharacterIntent(
            moveX: (values['moveX'] as num).toDouble(),
            moveZ: (values['moveZ'] as num).toDouble(),
          );
        case 'ai.drive':
          vehicle = VehicleIntent(
            throttle: (values['throttle'] as num).toDouble(),
            brake: (values['brake'] as num).toDouble(),
            steer: (values['steering'] as num).toDouble(),
          );
        case 'ai.interact':
          interact?.call(actor.identity.entity);
        default:
          throw StateError(
            'Unknown scripted controller command ${command.action}.',
          );
      }
    }
    if (actor.definition.profile == 'guard') {
      actor.control!.applyCharacter(character);
    } else {
      actor.control!.applyVehicle(vehicle);
    }
  }

  void _sense(GameSession session) {
    final host = runtime(), simulation = host.simulation!;
    final bindings = {
      for (final entity in session.entities.entities)
        if (host.isEntityActive(entity.handle) &&
            entity.components.any(
              (c) => c.type == 'game.character' || c.type == 'game.vehicle',
            ))
          entity.handle: ?host.resolveBody(entity.handle),
    };
    final colliders = {
      for (final entity in session.entities.entities)
        if (host.resolveCollider(entity.handle) case final collider?)
          collider.id: SensorCollider(
            SensorMaterial.opaque,
            entity: entity.handle,
          ),
    };
    _sounds.removeWhere((sound) => session.tick - sound.tick > 30);
    final snapshot = SensorSnapshot.fromPhysics(
      episodeId: _group!.episodeId,
      tick: session.tick,
      worldRevision: session.tick,
      world: simulation.world,
      bindings: bindings,
      colliders: colliders,
      currentRevision: () => session.tick,
      geometryLoaded: (_, _) => !host.isClosed,
      grounded: {
        for (final actor in bindings.keys) actor: ?host.actorGrounded(actor),
      },
      sounds: _sounds.map(SensorSoundSample.fromEvent).toList(),
    );
    for (final entry in _actors.entries) {
      if (!host.isEntityActive(entry.key)) continue;
      final actor = entry.value;
      if (actor.camera != null) {
        final awareness = actor.awareness.build(snapshot, entry.key);
        final baseline = actor.definition.profile == 'vehicle'
            ? actor.observer.build(snapshot, entry.key)
            : awareness;
        actor.scripted.observe(baseline);
        _senseVisual(actor, snapshot);
        continue;
      }
      final frame = actor.frame = actor.observer.build(snapshot, entry.key);
      final awareness = actor.awareness.build(snapshot, entry.key);
      actor.scripted.observe(
        actor.definition.profile == 'vehicle' ? frame : awareness,
      );
      if (actor.policy != null) actor.brain.observe(frame);
      final policy = actor.policy;
      if (policy == null || actor.control?.isActive != true) continue;
      policy.observe(frame);
      final context = _context(actor, scripted: false);
      if (actor.brain is HybridBrain &&
          context.goals.single.skill != 'learned') {
        if (policy.hasPending) policy.invalidatePending(preserveState: true);
        continue;
      }
      _group!.record(context);
      unawaited(
        policy
            .request(context, legality: context.legality)
            .catchError((Object _) => null),
      );
    }
    onChanged?.call();
  }

  /// Offline workers await this between ticks; visible play keeps its fixed clock.
  Future<void> flush() async {
    await Future.wait(_cameraJobs.toList());
    await _scheduler?.flush();
    await Future.wait([
      for (final actor in _actors.values) ?actor.policy?.pending,
      ..._retiring,
    ]);
  }

  Map<String, Object?> inspect(GameEntityHandle handle) {
    final actor = _actors[handle];
    if (_closed || actor == null || !_session!.entities.isAlive(handle)) {
      throw StateError('AI actor is no longer available.');
    }
    return {
      'brain': actor.definition.brain,
      'profile': actor.definition.profile,
      'cameraMode': actor.definition.cameraMode,
      if (actor.camera != null) 'cameraFailure': actor.camera!.failure,
      'pendingCameraCaptures': pendingCameraCaptures,
      'reservedCameraOutputBytes': reservedCameraOutputBytes,
      'activeBrain': actor.policy == null ? 'scripted' : actor.definition.brain,
      'modelFailure': _policyFailures[handle.id],
      if (actor.policy != null) ..._group!.inspect(handle),
      'knowledge': 'Historical permitted observations',
      'beliefs': actor.scripted.memory
          .atTick(_session!.tick)
          .map(
            (belief) => {
              'observedTick': belief.observedTick,
              'ageTicks': belief.ageTicks,
              'source': belief.source.name,
              'confidence': belief.confidence,
              'position': belief.position?.storage,
            },
          )
          .toList(),
      'observation': actor.frame?.tensor.float32Values,
      'sensors': [
        for (final reading in actor.frame?.readings ?? <SensorReading>[])
          {
            'id': reading.sensorId,
            'state': reading.state.name,
            'reason': reading.reason,
          },
      ],
      'completedDecisions': completedDecisions,
      'fallbackTicks': fallbackTicks,
      'scriptedTicks': scriptedTicks,
    };
  }

  /// The last immutable frame sampled through this actor's permitted sensors.
  /// It contains no current hidden world transforms or unrestricted scene data.
  ObservationFrame? observation(GameEntityHandle handle) {
    final actor = _actors[handle];
    if (_closed || actor == null || !_session!.entities.isAlive(handle)) {
      throw StateError('AI actor is no longer available.');
    }
    return actor.frame;
  }

  /// Completed pixels for the actor's current permitted observation tick.
  CameraObservation? cameraObservation(GameEntityHandle handle) {
    observation(handle);
    return _actors[handle]?.camera?.latest;
  }

  TrainingVisualProfile? visualProfile(GameEntityHandle handle) {
    observation(handle);
    return _actors[handle]?.camera?.profile;
  }

  void _pause(GameSession session) {
    for (final actor in _actors.values) {
      actor.suspended = actor.control != null || actor.suspended;
      actor.control?.dispose();
      actor.control = null;
      actor.frame = null;
      actor.camera?.invalidate();
      actor.policy?.synchronize(
        gameEpoch: session.epoch,
        controlEpoch: 0,
        paused: true,
        preserveCommittedState: true,
      );
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    Object? first;
    StackTrace? trace;
    Future<void> cleanup(FutureOr<void> Function() operation) async {
      try {
        await operation();
      } catch (e, s) {
        first ??= e;
        trace ??= s;
      }
    }

    // A cancelled launch can finish preparation before any system starts.
    await cleanup(() async {
      try {
        await _warming;
      } catch (_) {
        /* The launch reports this error. */
      }
    });
    _restored?.dispose();
    _topology?.dispose();
    _spawnValidator?.dispose();
    _events?.cancel();
    _codec?.cancel();
    await cleanup(() => _closeBrains(_actors.values.toList(), _group));
    _actors.clear();
    await cleanup(() => Future.wait(_retiring.toList()));
    if (_retirementError != null) {
      first ??= _retirementError;
      trace ??= _retirementTrace;
    }
    for (final lease in _leases) {
      await cleanup(() => cache.release(lease));
    }
    _leases.clear();
    await cleanup(
      () => _scheduler == null ? cache.close() : _scheduler!.close(),
    );
    _sounds.clear();
    onChanged?.call();
    if (first != null) Error.throwWithStackTrace(first!, trace!);
  }

  static Future<void> _closeBrains(
    List<_RuntimeBrain> actors,
    PolicyGroup? group,
  ) async {
    Object? first;
    StackTrace? trace;
    for (final actor in actors) {
      actor.control?.dispose();
      try {
        await actor.camera?.close();
      } catch (e, s) {
        first ??= e;
        trace ??= s;
      }
      for (final brain in {actor.brain, actor.scripted}) {
        try {
          await brain.close();
        } catch (e, s) {
          first ??= e;
          trace ??= s;
        }
      }
    }
    try {
      await group?.close();
    } catch (e, s) {
      first ??= e;
      trace ??= s;
    }
    if (first != null) Error.throwWithStackTrace(first, trace!);
  }
}

final class _RuntimeBrain {
  final BrainIdentity identity;
  final GameAiAuthoringDefinition definition;
  final ObservationAssembler observer, awareness;
  final GameBrain brain;
  final ScriptedBrain scripted;
  final PolicyBrain? policy;
  GameRuntimeActorControl? control;
  ObservationFrame? frame;
  _RuntimeCamera? camera;
  bool suspended = false;
  int lastCountedVersion = 0;
  _RuntimeBrain(
    this.identity,
    this.definition,
    this.observer,
    this.awareness,
    this.brain,
    this.scripted,
    this.policy,
  );
}

final class _AiDecisions extends GameSystem {
  final GameLevelAi owner;
  _AiDecisions(this.owner);
  @override
  String get id => 'game.ai.decisions';
  @override
  GamePhase get phase => GamePhase.decisions;
  @override
  void fixedUpdate(GameSession session) => owner._decide(session);
}

final class _AiSensors extends GameSystem {
  final GameLevelAi owner;
  _AiSensors(this.owner);
  @override
  String get id => 'game.ai.sensors';
  @override
  GamePhase get phase => GamePhase.sensors;
  @override
  Set<String> get dependencies => {'game.play-setup'};
  @override
  void start(GameSession session) => owner._start(session);
  @override
  void fixedUpdate(GameSession session) => owner._sense(session);
  @override
  void pause(GameSession session) => owner._pause(session);
  @override
  Future<void> dispose(GameSession session) => owner.close();
}

/// Hybrid routing selects the baseline; its own goal selector uses memory.
final class _BaselineSkill implements GameBrainCheckpointIdentity {
  final ScriptedBrain brain;
  _BaselineSkill(this.brain);
  @override
  BrainIdentity get identity => brain.identity;
  @override
  bool get checkpointQuiescent => true;
  @override
  void observe(ObservationFrame frame) {
    // The host supplies this baseline with its separate awareness sensor frame.
  }
  @override
  BrainDecision decide(BrainContext context) => brain.decide(
    BrainContext(
      identity: context.identity,
      tick: context.tick,
      gameEpoch: context.gameEpoch,
      controlEpoch: context.controlEpoch,
      observation: context.observation,
      beliefs: context.beliefs,
      goals: [],
      validTargets: context.validTargets,
      actionSpec: context.actionSpec,
      utilityInputs: context.utilityInputs,
    ),
  );
  @override
  void reset(BrainReset reset) => brain.reset(reset);
  @override
  Future<void> close() => brain.close();
}
