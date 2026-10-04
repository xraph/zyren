import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_game_ai/artifact.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_game_native/animation.dart';
import 'package:zyren_game_native/gameplay.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/scene.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'reference_world.dart';

/// Lifecycle contract shared by the game host and its presentation.
abstract class GameLabRun extends ChangeNotifier {
  GameLevelRuntime get runtime;
  SceneController get controller;
  GameLevelGameplay get gameplay;
  GameActionState get actions;
  GameLevelAi? get ai => null;
  GameSession get session;
  Object? get error;
  void togglePause();
  void step();
  Future<void> close();
}

/// The production entrypoint imports no Studio code and resolves no network URI.
final class GameLabSession extends GameLabRun {
  final CompiledGameProject project;
  final GameRuntimeScene scene;
  final Map<String, ModelArtifact> modelArtifacts;
  @override
  late final GameLevelAi ai;
  late final MlModelCache _models;
  @override
  late final GameLevelRuntime runtime;
  @override
  late final SceneController controller;
  @override
  late final GameLevelGameplay gameplay;
  final GameEventJournal journal = GameEventJournal();
  final GameActionState _loadingActions = GameActionState(
    GameInputMap(actions: [GameActionDefinition('loading')], bindings: []),
  )..enabled = false;
  Future<void>? _closing;
  bool _closed = false, _notificationQueued = false;
  @override
  Object? error;
  GameLabSession._(this.project, this.scene, Map<String, ModelArtifact> models)
    : modelArtifacts = Map.unmodifiable(models);
  @override
  GameActionState get actions => runtime.actions ?? _loadingActions;
  @override
  GameSession get session => runtime.simulation!.session;

  static Future<GameLabSession> load(
    Uint8List bytes, {
    SceneRuntime rendering = const SceneRuntime(),
    List<ScenePlugin> pluginsBeforeRuntime = const [],
    void Function(int tick, Duration elapsed)? onStepMeasured,
    void Function(String id, int tick, Duration elapsed)? onSystemMeasured,
  }) async {
    final library = GameRuleLibrary();
    final registry = GameRegistry();
    registerGameComponentCodecs(registry);
    registerGameLevelCodecs(registry);
    registerGameAiCodecs(registry);
    registry.registerComponent(
      GameRuleComponentCodec(library.actions, library.predicates),
    );
    registry.registerComponent(
      GameStateMachineComponentCodec(library.actions, library.predicates),
    );
    final bundle = PipelineBundle.decode(bytes);
    final project = CompiledGameProject.decode(
      utf8.decode(bundle.resource('game.recipe').bytes),
      registry,
    );
    for (final reference in project.assets) {
      final resource = bundle.resource(reference.id);
      if (resource.digest != reference.digest ||
          resource.source.revision != reference.revision ||
          resource.source.uri != reference.uri) {
        throw StateError('The exported asset does not match its runtime pin.');
      }
    }
    final models = <String, ModelArtifact>{};
    if (project.project.modelReferences.length > 8) {
      throw StateError('The game model catalog exceeds eight policies.');
    }
    for (final value in project.project.modelReferences.values) {
      final pin = PipelineAssetReference.fromJson(
        Map<String, Object?>.from(value as Map),
      );
      final resource = bundle.resource(pin.sourceId);
      if (resource.digest != pin.sha256 ||
          resource.source.revision != pin.sourceRevision ||
          resource.source.uri != pin.uri) {
        throw StateError('The exported model does not match its authored pin.');
      }
      final prefix = 'model.${pin.sha256}.';
      final artifact =
          ModelArtifact.decode(bundle.resource('${prefix}bundle.json').bytes, {
            for (final name in ModelArtifact.fileNames)
              name: bundle.resource('$prefix$name').bytes,
          });
      if (artifact.contract.model.sha256 != pin.sha256 ||
          artifact.fixedHz != project.fixedHz) {
        throw StateError(
          'The model acceptance receipt has different timing or bytes.',
        );
      }
      models[pin.sha256] = artifact;
    }
    final data = await GameRuntimeScene.load(
      project,
      loadAsset: (ref, token) async {
        final scope = bundle.open(services: rendering.assetServices);
        final task = scope.load(bundle.gltfRequest(sourceId: ref.id));
        final cancel = token.onCancel(task.cancel);
        try {
          final model = await task.result;
          token.throwIfCancelled();
          return GameSceneAsset(root: model.instantiate(), close: scope.close);
        } catch (_) {
          await scope.close();
          rethrow;
        } finally {
          cancel.dispose();
        }
      },
    );
    data.scene.background = Color3.hex(0x17202b);
    data.scene.ambient = .5;
    final host = GameLabSession._(project, data, models);
    MlModelCache? preparedCache;
    GameLevelAi? preparedAi;
    GameLevelRuntime? preparedRuntime;
    var controllerCreated = false;
    try {
      host._models = preparedCache = MlModelCache(
        manifestResolver: (manifest) async {
          final artifact = models[manifest.sha256];
          if (artifact == null ||
              artifact.contract.model.encode() != manifest.encode()) {
            throw StateError('The game requested an unregistered model.');
          }
          return artifact.files['actor.onnx']!;
        },
      );
      host.ai = preparedAi = GameLevelAi(
        runtime: () => host.runtime,
        cache: host._models,
        policies: {
          for (final entry in models.entries)
            entry.key: GameRuntimePolicy(
              contract: entry.value.contract,
              fixedHz: entry.value.fixedHz,
              evaluationHash: entry.value.evaluation.receiptHash,
            ),
        },
        onChanged: host._changed,
        openCameraBackend: (_, _) => NativeBackend.create(),
        interact: (actor) {
          final candidate = host.gameplay.available(actor).firstOrNull;
          return candidate != null &&
              host.gameplay.interact(actor, candidate.id);
        },
      );
      host.runtime = preparedRuntime = GameLevelRuntime(
        project: project,
        scene: data.scene,
        camera: data.camera,
        objects: data.objects,
        animationFactory: createGameCharacterAnimation,
        onChanged: host._changed,
        onStepMeasured: onStepMeasured,
        onSystemMeasured: onSystemMeasured,
        resources: [
          GameRuntimeResourceLease(close: data.close),
          GameRuntimeResourceLease(close: host.ai.close),
        ],
        systemFactory: (runtime) => [
          host.gameplay = GameLevelGameplay(runtime, library),
          host.journal,
          GameReferenceWorld(runtime),
          ...host.ai.systems,
        ],
      );
      await host.runtime.initialize();
      await host.ai.warmup();
      host.controller = SceneController(
        scene: data.scene,
        camera: data.camera,
        runtime: rendering,
        options: const EngineOptions(
          presentation: PresentationPolicy.requireNative,
        ),
      );
      controllerCreated = true;
      for (final plugin in pluginsBeforeRuntime) {
        host.controller.use(plugin);
      }
      for (final plugin in host.runtime.plugins) {
        host.controller.use(plugin);
      }
      host.controller.ready.then<void>(
        (_) => host._changed(),
        onError: (Object e, StackTrace _) {
          if (!host._closed) {
            host.error = e;
            host._changed();
          }
        },
      );
      return host;
    } catch (error, stack) {
      host._closed = true;
      Future<void> cleanup(Future<void> Function() close) async {
        try {
          await close();
        } catch (cleanupError, cleanupStack) {
          FlutterError.reportError(
            FlutterErrorDetails(
              exception: cleanupError,
              stack: cleanupStack,
              library: 'Zyren Game Lab',
              context: ErrorDescription('while cleaning up a failed game load'),
            ),
          );
        }
      }

      if (controllerCreated) {
        await cleanup(() async {
          host.controller.dispose();
          await host.controller.whenDisposed;
        });
      }
      if (preparedAi != null) {
        await cleanup(preparedAi.close);
      } else if (preparedCache != null) {
        await cleanup(preparedCache.close);
      }
      if (preparedRuntime != null) await cleanup(preparedRuntime.close);
      if (preparedRuntime?.resourcesAdopted != true) await cleanup(data.close);
      host.dispose();
      Error.throwWithStackTrace(error, stack);
    }
  }

  void _changed() {
    if (_closed || _notificationQueued) return;
    _notificationQueued = true;
    scheduleMicrotask(() {
      _notificationQueued = false;
      if (!_closed) notifyListeners();
    });
  }

  @override
  void togglePause() {
    if (session.paused) {
      runtime.resume();
    } else {
      runtime.pause();
    }
  }

  @override
  void step() {
    runtime.step();
    controller.invalidate();
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    Object? failure;
    StackTrace? stack;
    try {
      controller.dispose();
      await controller.whenDisposed;
    } catch (e, s) {
      failure = e;
      stack = s;
    }
    try {
      await ai.close();
    } catch (e, s) {
      failure ??= e;
      stack ??= s;
    }
    try {
      await runtime.close();
    } catch (e, s) {
      failure ??= e;
      stack ??= s;
    }
    dispose();
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }
}
