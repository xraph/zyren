import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'benchmark.dart';
import 'game_session.dart';
import 'native_platform.dart';

/// Verify the native brains that are running, including hybrid model failures
/// that the ordinary game is allowed to recover from with scripted behavior.
void verifyGameBenchmarkPolicies(
  GameLabSession run,
  Map<String, PolicyContract> expected,
) {
  final actors = {for (final actor in run.ai.actors) actor.id: actor};
  for (final entry in expected.entries) {
    final actor = actors[entry.key];
    final brain = actor == null ? null : run.ai.group?.brainFor(actor);
    if (actor == null ||
        !run.session.entities.isAlive(actor) ||
        !run.runtime.isEntityActive(actor) ||
        brain == null ||
        brain.contract.hash != entry.value.hash) {
      throw StateError('${entry.key} has no live matching benchmark policy.');
    }
  }
}

final class _FrameProbe extends ScenePlugin {
  final GameBenchmarkHost owner;
  final Map<int, Stopwatch> _submitted = {};
  final _unmeasured = <int>{};
  Stopwatch? _preparing;
  _FrameProbe(this.owner);
  @override
  String get id => 'game-lab.benchmark.begin';
  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    _preparing = owner.measuring ? (Stopwatch()..start()) : null;
  }

  @override
  void afterRender(PluginContext context, FrameInfo frame, FrameStats stats) {
    if (_preparing case final watch?) {
      if (_submitted.length >= 8) {
        throw StateError('Unconsumed presentation receipts.');
      }
      _submitted[stats.frameId] = watch;
    } else {
      if (_unmeasured.length >= 8) {
        throw StateError('Unconsumed warmup presentation receipts.');
      }
      _unmeasured.add(stats.frameId);
    }
    _preparing = null;
  }

  void presented(PresentationSample sample) {
    final watch = _submitted.remove(sample.frame.frameId);
    if (_unmeasured.remove(sample.frame.frameId)) return;
    if (!owner.measuring) return;
    if (watch == null) {
      throw StateError('Presentation lacks its preparation timestamp.');
    }
    owner.recorder.fullFrame(watch.elapsedMicroseconds);
    owner.recorder.presentation(
      intervalMicros: sample.interval?.inMicroseconds,
      readback: sample.frame.readbackBytes,
      width: sample.frame.physicalSize.width,
      height: sample.frame.physicalSize.height,
      cpuBuildMicros: sample.frame.cpuBuildTime.inMicroseconds,
      cpuSubmitMicros: sample.frame.cpuSubmitTime.inMicroseconds,
      gpuMicros: sample.frame.gpuTime?.inMicroseconds,
    );
  }
}

final class _CameraMovement extends ScenePlugin {
  final GameBenchmarkHost owner;
  int _tick = -1;
  Vec3? _anchor;
  _CameraMovement(this.owner);
  @override
  String get id => 'game-lab.benchmark.camera';
  @override
  Set<String> get dependencies => const {'zyren.game'};
  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (!owner.measuring) return;
    final run = owner.game.value!;
    final camera = run.scene.camera;
    if (_tick != run.session.tick) {
      _tick = run.session.tick;
      _anchor = camera.position;
    }
    final t = frame.elapsed.inMicroseconds / 1000000;
    camera.position = _anchor! + Vec3(math.sin(t) * .2, math.cos(t) * .1, 0);
    owner.recorder.lifecycle('camera-movement');
  }
}

/// Drives the actual GameLab host and presenter. No second simulation clock,
/// synthetic camera tensor or awaited inference is inserted into realtime play.
final class GameBenchmarkHost {
  final GameBenchmarkProfile profile;
  final Uint8List bundle;
  final String device, buildHash;
  final bool physicalDevice;
  late final recorder = GameBenchmarkRecorder(profile);
  final game = ValueNotifier<GameLabSession?>(null);
  final status = ValueNotifier<String>('Preparing native game');
  final _invalidByBrain = <PolicyBrain, int>{};
  final _lastReceipt = <PolicyBrain, PolicyReceipt?>{};
  final _observed = <GameEntityHandle, int>{};
  final _cameraTicks = <GameEntityHandle, int>{};
  final _visualActors = <String>{}, _seenVisualActors = <String>{};
  final _declaredPolicies = <String, PolicyContract>{};
  final _expected = <String, (GameEntityHandle, int)>{};
  final _baselinePhysics = PhysicsWorld.nativeCounts;
  Map<String, int>? _baselineNative, _finalNative;
  late final _baselineMl = _mlOwners();
  int _fallback = 0, _scripted = 0;
  StreamSubscription<PresentationSample>? _presentations;
  StreamSubscription<MlBatchReceipt>? _batches;
  StreamSubscription<GameClockWake>? _clockEvents;
  double _lastClockDropped = 0;
  GameEventSubscription? _ticks;
  RendererInfo? _renderer;
  Object? _captureError;
  bool measuring = false, _loadVerified = false, _actorLoadVerified = false;
  Future<void>? _closing;
  int _segment = 0, _epoch = -1;
  GameBenchmarkHost({
    required this.profile,
    required this.bundle,
    required this.device,
    required this.buildHash,
    required this.physicalDevice,
  });

  Future<void> load() async {
    _actorLoadVerified = false;
    _baselineNative ??= await gameLabNativeOwners();
    // Read the lazy baseline before the first model owner is created.
    _baselineMl;
    final probe = _FrameProbe(this);
    final next = await GameLabSession.load(
      bundle,
      rendering: gameLabRendering(),
      pluginsBeforeRuntime: [probe],
      onStepMeasured: (_, elapsed) {
        if (measuring) recorder.gameCpu(elapsed.inMicroseconds);
      },
      onSystemMeasured: (id, _, elapsed) {
        if (measuring) recorder.systemCpu(id, elapsed.inMicroseconds);
      },
    );
    try {
      _validateLoad(next);
      next.controller.use(_CameraMovement(this));
      _segment++;
      _observed.clear();
      _cameraTicks.clear();
      _seenVisualActors.clear();
      _expected.clear();
      _invalidByBrain.clear();
      _lastReceipt.clear();
      _fallback = _scripted = 0;
      _epoch = -1;
      _ticks = next.session.listenState(_tick);
      next.addListener(_visualCapture);
      _presentations = next.controller.presentations.listen(probe.presented);
      game.value = next;
      _loadVerified = true;
    } catch (_) {
      await next.close();
      rethrow;
    }
  }

  void _validateLoad(GameLabSession run) {
    _visualActors.clear();
    _declaredPolicies.clear();
    if (run.project.fixedHz != profile.fixedHz) {
      throw UnsupportedError(
        'Profile ${profile.id} requires ${profile.fixedHz} Hz; '
        'the exported game and evaluated policies use ${run.project.fixedHz} Hz.',
      );
    }
    var guards = 0, vehicles = 0, cameras = 0;
    for (final entity
        in run.project.levels
            .singleWhere((l) => l.id == run.project.project.startupLevel)
            .entities) {
      final component = entity.components
          .where((c) => c.type == 'game.ai')
          .firstOrNull;
      if (component == null) continue;
      final definition = GameAiAuthoringDefinition(component.data);
      final model = run.modelArtifacts[definition.modelHash];
      if (model == null || definition.brain == 'scripted') {
        throw UnsupportedError(
          'Every benchmark actor needs its accepted policy.',
        );
      }
      _declaredPolicies[entity.id] = model.contract;
      final hz = run.project.fixedHz / model.contract.cadenceTicks;
      if (definition.profile == 'guard') {
        guards++;
        if (hz != profile.guardHz) {
          throw UnsupportedError('Guard policy cadence differs from profile.');
        }
      } else {
        vehicles++;
        if (hz != profile.vehicleHz) {
          throw UnsupportedError(
            'Vehicle policy cadence differs from profile.',
          );
        }
      }
      if (definition.visualProfile case final visual?) {
        if (model.contract.encoder is! VisualPolicyEncoder ||
            visual.camera.width != profile.width ||
            visual.camera.height != profile.height ||
            run.project.fixedHz / visual.camera.cadenceTicks !=
                profile.cameraHz) {
          throw UnsupportedError(
            'Camera policy dimensions or cadence differ from profile.',
          );
        }
        cameras++;
        _visualActors.add(entity.id);
      }
    }
    if (guards != profile.guards ||
        vehicles != profile.vehicles ||
        cameras != profile.cameras) {
      throw UnsupportedError(
        'Exported actor/camera counts differ from profile: '
        '$guards guards, $vehicles vehicles, $cameras cameras.',
      );
    }
  }

  Future<void> ready() async {
    _renderer = await game.value!.controller.ready.timeout(
      const Duration(seconds: 90),
    );
    final watch = Stopwatch()..start();
    while (game.value!.ai.group == null || game.value!.session.tick == 0) {
      _requireHealthy();
      if (watch.elapsed > const Duration(seconds: 90)) {
        throw StateError('Native game did not begin stepping.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    verifyGameBenchmarkPolicies(game.value!, _declaredPolicies);
    _actorLoadVerified = true;
  }

  void _requireHealthy() {
    final run = game.value!;
    if (_captureError != null) throw StateError('$_captureError');
    if (run.error != null || run.runtime.error != null) {
      throw StateError('${run.error ?? run.runtime.error}');
    }
    if (_actorLoadVerified) {
      verifyGameBenchmarkPolicies(run, _declaredPolicies);
    }
  }

  void _timings(List<FrameTiming> timings) {
    if (!measuring) return;
    for (final timing in timings) {
      recorder.flutterFrame(timing.totalSpan.inMicroseconds);
    }
  }

  void _visualCapture() {
    try {
      _recordVisualCapture();
    } catch (error) {
      _captureError ??= error;
    }
  }

  void _recordVisualCapture() {
    final run = game.value;
    if (!measuring || run == null) return;
    for (final actor in run.ai.actors) {
      if (!_visualActors.contains(actor.id)) continue;
      final capture = run.ai.cameraObservation(actor);
      if (capture == null || _cameraTicks[actor] == capture.receipt.tick) {
        continue;
      }
      if (capture.entity != actor ||
          capture.receipt.tick != run.session.tick ||
          capture.receipt.width != profile.width ||
          capture.receipt.height != profile.height ||
          capture.receipt.stats.readbackBytes <= 0) {
        _captureError =
            'Native camera receipt differs from its live actor or profile.';
        return;
      }
      recorder.cameraCapture(
        captureMicros: capture.receipt.elapsed.inMicroseconds,
        preprocessingMicros: capture.preprocessingTime.inMicroseconds,
        readbackBytes: capture.receipt.stats.readbackBytes,
        reservedBytes: run.ai.reservedCameraOutputBytes,
      );
      _cameraTicks[actor] = capture.receipt.tick;
      _seenVisualActors.add(actor.id);
    }
  }

  void _tick() {
    final run = game.value;
    if (run == null) return;
    final clock = run.session.realtimeClock;
    if (_clockEvents == null && clock != null) {
      _lastClockDropped = run.session.droppedSeconds;
      _clockEvents = clock.measurements.listen((wake) {
        if (measuring) {
          recorder.clockWake(
            latenessMicros: wake.latenessMicros,
            pendingSteps: wake.pendingSteps,
            advanced: wake.advanced,
            droppedSeconds: wake.droppedSeconds - _lastClockDropped,
          );
        }
        _lastClockDropped = wake.droppedSeconds;
      });
    }
    final group = run.ai.group;
    if (group != null && _batches == null) {
      _batches = group.ml.batches.listen((batch) {
        if (!measuring) return;
        for (final value in batch.results.values) {
          recorder.inferenceOutcome(value.status.name);
          recorder.inference(
            (value.timing.queue + value.timing.workerRoundTrip).inMicroseconds,
          );
        }
      });
    }
    if (group == null) return;
    for (final actor in run.ai.actors) {
      final brain = group.brainFor(actor);
      if (brain == null) continue;
      final previous = _invalidByBrain[brain] ?? 0;
      if (measuring) recorder.invalidActions += brain.invalidOutputs - previous;
      _invalidByBrain[brain] = brain.invalidOutputs;
      final receipts = brain.decisions.receipts;
      final old = _lastReceipt[brain];
      final first = old == null ? 0 : receipts.indexOf(old) + 1;
      if (measuring) {
        for (final receipt in receipts.skip(first)) {
          if (!receipt.accepted) recorder.rejectedActions++;
          if (receipt.accepted &&
              receipt.applicationTick != receipt.applyTick) {
            recorder.staleApplied++;
          }
        }
      }
      _lastReceipt[brain] = receipts.lastOrNull;
    }
    if (measuring) {
      recorder.fallbackTicks += run.ai.fallbackTicks - _fallback;
      recorder.scriptedTicks += run.ai.scriptedTicks - _scripted;
    }
    _fallback = run.ai.fallbackTicks;
    _scripted = run.ai.scriptedTicks;
    if (!measuring) return;
    final session = run.session;
    if (_epoch != session.epoch || session.paused) {
      recorder.cancelDecisions(_expected.keys.toList());
      _expected.clear();
      _observed.clear();
      _epoch = session.epoch;
    }
    if (session.paused) return;
    for (final entry in _expected.entries.toList()) {
      final applicationTick = recorder.applicationTick(entry.key)!;
      if (applicationTick > session.tick) continue;
      final brain = group.brainFor(entry.value.$1);
      final accepted =
          brain?.decisions.receipts.any(
            (r) =>
                r.accepted &&
                r.observationTick == entry.value.$2 &&
                r.applyTick == applicationTick &&
                r.applicationTick == session.tick,
          ) ==
          true;
      recorder.resolveDecision(
        entry.key,
        currentTick: session.tick,
        accepted: accepted,
      );
      _expected.remove(entry.key);
    }
    final actors = {for (final actor in run.ai.actors) actor.id: actor};
    for (final entry in _declaredPolicies.entries) {
      final actor = actors[entry.key], contract = entry.value;
      if (actor == null ||
          !run.runtime.isEntityActive(actor) ||
          group.brainFor(actor) == null) {
        _actorLoadVerified = false;
        _captureError = '${entry.key} lost its active benchmark policy.';
        continue;
      }
      if (_observed[actor] == session.tick ||
          session.tick % contract.cadenceTicks != 0) {
        continue;
      }
      // An absent or stale observation still owes a decision at this cadence.
      final key = '$_segment:${actor.id}@${actor.generation}/${session.tick}';
      recorder.expectDecision(key, session.tick + contract.latencyTicks);
      _expected[key] = (actor, session.tick);
      _observed[actor] = session.tick;
      final frame = run.ai.observation(actor);
      if (frame == null || frame.tick != session.tick) {
        recorder.observation('frame', 'unknown', 'current-observation-missing');
        continue;
      }
      for (final reading in frame.readings) {
        recorder.observation(
          reading.sensorId,
          reading.state.name,
          reading.reason,
        );
      }
    }
    final d = group.ml.diagnostics;
    recorder.cameraReservation(run.ai.reservedCameraOutputBytes);
    recorder.memory(
      rss: ProcessInfo.currentRss,
      weights: d.modelWeightsBytes,
      tensors: d.queuedTensorBytes + d.inFlightTensorBytes,
      recurrent: group.stateBytes,
    );
  }

  Future<void> _pauseAndPool() async {
    final run = game.value!;
    run.runtime.pause();
    recorder.lifecycle('pause');
    await run.ai.flush();
    final actor = run.ai.actors.first;
    final record = run.runtime.entityDefinition(actor.id)!;
    final template = GameSpawnTemplate(
      id: 'benchmark-pool',
      registry: run.project.project.registry,
      entities: [
        GameEntityRecord(
          id: 'actor',
          nodeId: 'actor',
          components: record.components,
        ),
      ],
    );
    final slot = await run.runtime.prepareSpawn(
      template,
      instanceId: 'benchmark-spawn',
      prepare: (records) async => GameRuntimeSpawnResources(
        objects: {
          records.single.nodeId!: Group()
            ..position =
                run.runtime.resolveBody(actor)!.state.pose.position +
                const Vec3(3, 0, 0)
            ..add(
              Mesh(
                BoxGeometry(),
                UnlitMaterial(color: const Color3(.4, .7, .5)),
              ),
            ),
        },
      ),
    );
    run.runtime.activateSpawn(slot);
    recorder.lifecycle('spawn');
    final started = run.session.tick;
    run.runtime.resume();
    recorder.lifecycle('resume');
    final wait = Stopwatch()..start();
    while (run.session.tick < started + 3) {
      _requireHealthy();
      if (wait.elapsed > const Duration(seconds: 10)) {
        throw StateError('Spawned actor never entered realtime simulation.');
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    run.runtime.pause();
    await run.ai.flush();
    run.runtime.retireSpawn(slot);
    recorder.lifecycle('despawn');
    await run.ai.flush();
    await run.runtime.releaseSpawn(slot);
    run.runtime.resume();
    recorder.lifecycle('resume');
  }

  Future<void> _recreate() async {
    final run = game.value!;
    final saved = await run.ai.save();
    await _detach();
    game.value = null;
    await run.close();
    await load();
    await ready();
    await game.value!.ai.restore(saved);
    game.value!.runtime.resume();
    recorder.lifecycle('renderer-recreated');
  }

  Future<void> _detach() async {
    game.value?.removeListener(_visualCapture);
    _ticks?.cancel();
    _ticks = null;
    await _clockEvents?.cancel();
    _clockEvents = null;
    await _batches?.cancel();
    _batches = null;
    await _presentations?.cancel();
    _presentations = null;
    recorder.cancelDecisions(_expected.keys.toList());
    _expected.clear();
  }

  Future<Map<String, Object?>> execute({bool smoke = false}) async {
    await ready();
    final warmup = smoke ? 3 : 30;
    final seconds = smoke ? 10 : profile.seconds;
    status.value = 'Warming native rendering and policies for $warmup seconds';
    await Future<void>.delayed(Duration(seconds: warmup));
    _requireHealthy();
    SchedulerBinding.instance.addTimingsCallback(_timings);
    final watch = Stopwatch()..start();
    measuring = true;
    var exercised = false, recreated = false;
    try {
      while (watch.elapsed.inSeconds < seconds) {
        _requireHealthy();
        status.value = '${profile.id}: ${watch.elapsed.inSeconds}/$seconds s';
        if (!exercised && watch.elapsed.inSeconds >= seconds ~/ 3) {
          exercised = true;
          await _pauseAndPool();
        }
        if (!recreated && watch.elapsed.inSeconds >= seconds * 2 ~/ 3) {
          recreated = true;
          await _recreate();
        }
        await Future<void>.delayed(const Duration(seconds: 1));
      }
      _requireHealthy();
      final run = game.value!;
      final identity = <String, Object?>{
        'device': device,
        'physicalDevice': physicalDevice,
        'os': Platform.operatingSystemVersion,
        'renderer': _renderer?.backend,
        'adapter': _renderer?.adapterName,
        'provider': 'native-onnxruntime-1.23.2-cpu',
        'buildMode': kReleaseMode
            ? 'release'
            : kProfileMode
            ? 'profile'
            : 'debug',
        'buildHash': buildHash,
        'gameHash': run.project.buildId,
        'modelHashes': run.modelArtifacts.keys.toList()..sort(),
        'schemaHashes':
            run.modelArtifacts.values
                .map((a) => a.contract.observation.hash)
                .toList()
              ..sort(),
      };
      final duration = watch.elapsedMicroseconds / 1000000;
      measuring = false;
      await close();
      final wait = Stopwatch()..start();
      do {
        _finalNative = await gameLabNativeOwners();
        if (_nativeClean) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      } while (wait.elapsed < const Duration(seconds: 10));
      return {
        ...recorder.finish(
          durationSeconds: duration,
          identity: identity,
          cleanupVerified:
              mapEquals(PhysicsWorld.nativeCounts, _baselinePhysics) &&
              mapEquals(_mlOwners(), _baselineMl) &&
              _nativeClean,
          loadVerified: _loadVerified,
          nativePresentation:
              _renderer != null &&
              _renderer!.presentationPath != PresentationPath.readback,
          actorLoadVerified: _actorLoadVerified,
          visualInputsVerified:
              _visualActors.isNotEmpty &&
              _seenVisualActors.containsAll(_visualActors),
        ),
        'nativeOwnersBefore': _baselineNative,
        'nativeOwnersAfter': _finalNative,
        'mlOwnersBefore': _baselineMl,
        'mlOwnersAfter': _mlOwners(),
        'physicsOwnersBefore': _baselinePhysics,
        'physicsOwnersAfter': PhysicsWorld.nativeCounts,
      };
    } finally {
      measuring = false;
      SchedulerBinding.instance.removeTimingsCallback(_timings);
      await close();
    }
  }

  Future<void> close() => _closing ??= _close();
  bool get _nativeClean =>
      _baselineNative != null &&
      _finalNative != null &&
      mapEquals(_baselineNative, _finalNative);
  static Map<String, int> _mlOwners() {
    final d = const MlRuntime().diagnostics;
    return {
      'sessions': d.liveSessions,
      'results': d.liveResults,
      'runs': d.activeRuns,
    };
  }

  Future<void> _close() async {
    measuring = false;
    await _detach();
    final current = game.value;
    game.value = null;
    await current?.close();
  }
}

final class GameBenchmarkView extends StatelessWidget {
  final GameBenchmarkHost host;
  const GameBenchmarkView(this.host, {super.key});
  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: Column(
      children: [
        ValueListenableBuilder(
          valueListenable: host.status,
          builder: (_, value, _) =>
              Padding(padding: const EdgeInsets.all(8), child: Text(value)),
        ),
        Expanded(
          child: ValueListenableBuilder(
            valueListenable: host.game,
            builder: (_, game, _) => game == null
                ? const SizedBox.shrink()
                : SceneView(key: ObjectKey(game), controller: game.controller),
          ),
        ),
      ],
    ),
  );
}
