part of '../../play.dart';

final _playOwners = Expando<GamePlaySession>('Studio play owner');

enum GamePlayState { stopped, loading, running, paused, failed }

typedef GamePlayCharacterAnimation = GameCharacterAnimation;
typedef GamePlayAnimationFactory = GameCharacterAnimationFactory;

/// A launch owns independent native work and never applies its runtime scene.
final class GamePlaySession extends ChangeNotifier
    implements StudioEditorPlaySession {
  final StudioScene authoredScene;
  final SceneRuntime runtime;
  final StudioAssetResolver? assetResolver;
  final ModelAssetResolver? modelResolver;
  final Map<String, MlModelManifest> modelManifests;
  final SpatialAudio Function(StudioScene)? audioFactory;
  final GamePlayAnimationFactory? animationFactory;
  final List<GameSystem> Function(GamePlaySession)? systemFactory;
  final Future<GameRuntimeResourceLease?> Function(GamePlaySession)?
  prepareRuntime;
  final RendererFactory? fixtureRendererFactory;
  final int seed;
  final Set<String> capabilities;
  @override
  final String id;
  GamePlaySession({
    required this.authoredScene,
    this.runtime = const SceneRuntime(),
    this.assetResolver,
    this.modelResolver,
    Map<String, MlModelManifest> modelManifests = const {},
    this.audioFactory,
    this.animationFactory,
    this.systemFactory,
    this.prepareRuntime,
    this.fixtureRendererFactory,
    this.seed = 1,
    this.capabilities = const {},
    this.id = 'game.play',
  }) : modelManifests = Map.unmodifiable(modelManifests);
  GamePlayState _state = GamePlayState.stopped;
  GamePlayState get state => _state;
  Object? error;
  int? authoredRevision;
  String? _authoredDocument;
  CompiledGameProject? _project;
  StudioScene? _scene;
  StudioScene? get runtimeScene => _scene;
  StudioAssetScope? _assets;
  StudioAssetScope? get assetScope => _assets;
  MlModelCache? _models;
  MlModelCache? get models => _models;
  SpatialAudio? _audio;
  SpatialAudio? get audio => _audio;
  GameLevelRuntime? _levelRuntime;
  GameRuntimeResourceLease? _preparedRuntime;
  GameLevelRuntime? get levelRuntime => _levelRuntime;
  GameSimulation? get _simulation => _levelRuntime?.simulation;
  GameSimulation? get simulation => _simulation;
  SceneController? _controller;
  SceneController? get controller => _controller;
  SceneEngine? _fixtureEngine;
  PhysicsWorld? get world => _levelRuntime?.world;
  GamePossession? get possession => _levelRuntime?.possession;
  GameEntityHandle? get controlledActor => _levelRuntime?.controlledActor;
  GameEntityHandle? get inputActor => _levelRuntime?.inputActor;
  Map<GameEntityHandle, GameCharacterController> get animatedCharacters =>
      _levelRuntime?.animatedCharacters ?? const {};
  Map<GameEntityHandle, VehicleController> get vehicles =>
      _levelRuntime?.vehicles ?? const {};
  GameActionState? get actions => _levelRuntime?.actions;
  GameSave save() =>
      _levelRuntime?.save() ?? (throw StateError('No running game.'));
  void restore(GameSave save) {
    final runtime = _levelRuntime;
    if (runtime == null) throw StateError('No running game.');
    runtime.restore(save);
    _state = runtime.isPaused ? GamePlayState.paused : GamePlayState.running;
    _publish();
  }

  bool controlEntity(GameEntityHandle? target) =>
      _levelRuntime?.controlEntity(target) ?? false;
  PhysicsPose? exitPlacement(
    GameEntityHandle actor,
    GameEntityHandle vehicle,
  ) => _levelRuntime?.exitPlacement(actor, vehicle);
  GameEntityHandle? get runtimeSelection => _levelRuntime?.runtimeSelection;
  set runtimeSelection(GameEntityHandle? value) {
    final runtime = _levelRuntime;
    if (runtime == null) throw StateError('No runtime selection.');
    runtime.runtimeSelection = value;
  }

  void _runtimeChanged() {
    final session = _simulation?.session;
    if (_levelRuntime?.error != null) {
      error = _levelRuntime!.error;
      _state = GamePlayState.failed;
    } else if (session?.paused == true && _state == GamePlayState.running) {
      _state = GamePlayState.paused;
    }
    _controller?.invalidate();
    _publish();
  }

  int get tick => _simulation?.session.tick ?? 0;
  @override
  bool get isPaused => _state == GamePlayState.paused;
  StudioCancellation? _cancel;
  Future<void>? _launching, _stopping;
  int _generation = 0;
  bool _disposed = false;
  void _publish() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start(CompiledGameProject project) {
    if (_disposed ||
        _launching != null ||
        _stopping != null ||
        _simulation != null ||
        _playOwners[authoredScene] != null) {
      throw StateError('This authored scene already has a play owner.');
    }
    final generation = ++_generation;
    _playOwners[authoredScene] = this;
    _cancel = StudioCancellation();
    _state = GamePlayState.loading;
    error = null;
    authoredRevision = authoredScene.revision;
    _authoredDocument = authoredScene.capture().encode();
    _project = project;
    final launch = _launch(project, generation);
    _launching = launch;
    launch.then<void>(
      (_) {
        if (identical(_launching, launch)) _launching = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_launching, launch)) _launching = null;
      },
    );
    _publish();
    return launch;
  }

  void _checkLaunch(int generation) {
    _cancel!.throwIfCancelled();
    if (generation != _generation ||
        authoredScene.revision != authoredRevision ||
        authoredScene.capture().encode() != _authoredDocument) {
      throw const StaleApplyBack();
    }
  }

  Future<void> _launch(CompiledGameProject project, int generation) async {
    try {
      final document = StudioDocument.decode(_authoredDocument!);
      final level = project.levels.singleWhere(
        (l) => l.id == project.project.startupLevel,
      );
      if (level.scene.id != document.id ||
          level.scene.pin !=
              sha256.convert(utf8.encode(document.encode())).toString()) {
        throw StateError('Compile the current authored document before play.');
      }
      final nodes = project.sceneNodes[level.id];
      if (nodes == null) throw StateError('Compiled scene nodes are missing.');
      final runtimeDocument = document.copyWith(
        nodes: nodes.map((n) {
          final data = Map<String, dynamic>.from(n);
          if (data['kind'] == 'prefab') {
            data['kind'] = 'group';
            data.remove('prefabId');
            data.remove('overrides');
            data.remove('extensionOverrides');
          }
          return StudioNode.fromJson(data);
        }).toList(),
        prefabs: [],
        extensions: {},
      );
      if (runtimeDocument.expandedNodes.values.any((n) => n.assetId != null)) {
        if (assetResolver == null) {
          throw StateError('The play scene needs a pinned asset resolver.');
        }
        _assets = await StudioAssetScope.load(
          runtimeDocument,
          assetResolver!,
          cancellation: _cancel,
        );
      } else {
        _assets = StudioAssetScope();
      }
      _checkLaunch(generation);
      _scene = StudioScene(runtimeDocument, assets: _assets);
      if (project.project.modelReferences.isNotEmpty) {
        if (modelResolver == null ||
            modelManifests.keys
                .toSet()
                .difference(project.project.modelReferences.keys.toSet())
                .isNotEmpty ||
            !modelManifests.keys.toSet().containsAll(
              project.project.modelReferences.keys,
            )) {
          throw StateError(
            'Provide the exact authored model manifests and resolver.',
          );
        }
        _models = MlModelCache(resolver: modelResolver!);
        for (final entry in modelManifests.entries) {
          final pin = PipelineAssetReference.fromJson(
            Map<String, Object?>.from(
              project.project.modelReferences[entry.key] as Map,
            ),
          );
          if (pin.sha256 != entry.value.sha256 ||
              !project.assets.any(
                (asset) =>
                    asset.id == pin.sourceId &&
                    asset.digest == pin.sha256 &&
                    asset.revision == pin.sourceRevision &&
                    asset.uri == pin.uri,
              )) {
            throw StateError('Model manifest differs from compiled asset pin.');
          }
          await _models!.acquire(entry.value);
          _checkLaunch(generation);
        }
      } else {
        _models = MlModelCache(
          resolver:
              modelResolver ??
              ((_) async => throw StateError('No model is authored.')),
        );
      }
      _checkLaunch(generation);
      final assets = _assets!, models = _models!;
      final native = _levelRuntime = GameLevelRuntime(
        project: project,
        scene: _scene!.scene,
        camera: _scene!.camera,
        objects: _scene!.objects,
        seed: seed,
        capabilities: capabilities,
        animationFactory: animationFactory,
        systemFactory: (_) => systemFactory?.call(this) ?? [],
        onChanged: _runtimeChanged,
        resources: [
          GameRuntimeResourceLease(close: assets.close),
          GameRuntimeResourceLease(close: models.close),
          GameRuntimeResourceLease(
            close: () => _audio?.close(),
            pause: () => _audio?.suspend(),
            resume: () => _audio?.resume(),
          ),
        ],
      );
      await native.initialize();
      _checkLaunch(generation);
      _preparedRuntime = await prepareRuntime?.call(this);
      _checkLaunch(generation);
      _audio = audioFactory?.call(_scene!);
      final plugins = native.plugins;
      if (fixtureRendererFactory != null) {
        _fixtureEngine = await SceneEngine.create(
          scene: _scene!.scene,
          camera: _scene!.camera,
          rendererFactory: fixtureRendererFactory,
          plugins: plugins,
        );
        _checkLaunch(generation);
        _simulation!.step();
      } else {
        _controller = SceneController(
          scene: _scene!.scene,
          camera: _scene!.camera,
          runtime: runtime,
          options: const EngineOptions(
            presentation: PresentationPolicy.requireNative,
          ),
        );
        for (final plugin in plugins) {
          _controller!.use(plugin);
        }
        final controller = _controller!;
        controller.ready.then<void>(
          (_) {
            if (generation == _generation) _publish();
          },
          onError: (Object e, StackTrace s) {
            if (generation == _generation) {
              error = e;
              unawaited(
                stop().then((_) {
                  _state = GamePlayState.failed;
                  _publish();
                }),
              );
            }
          },
        );
      }
      _checkLaunch(generation);
      _state = native.isPaused ? GamePlayState.paused : GamePlayState.running;
      _publish();
    } catch (e) {
      error = e;
      await _disposeResources();
      if (generation == _generation) {
        _state = GamePlayState.failed;
        _publish();
      }
      rethrow;
    }
  }

  @override
  void pause() {
    if (_state != GamePlayState.running) {
      throw StateError('The play session is not running.');
    }
    _levelRuntime!.pause();
    _state = GamePlayState.paused;
    _publish();
  }

  @override
  void resume() {
    if (!isPaused) throw StateError('Pause before resuming.');
    _levelRuntime!.resume();
    _state = GamePlayState.running;
    _publish();
  }

  @override
  void step() {
    if (!isPaused) throw StateError('Pause before stepping.');
    try {
      _levelRuntime!.step();
    } finally {
      _runtimeChanged();
      _publish();
    }
  }

  PhysicsBody? resolveBody(GameEntityHandle handle) =>
      _levelRuntime?.resolveBody(handle);
  void setEntityActive(GameEntityHandle handle, bool active) {
    final native = _levelRuntime;
    if (native == null) throw StateError('No runtime entity.');
    native.setEntityActive(handle, active);
  }

  Map<String, Object?> inspectEntity(GameEntityHandle handle) {
    final native = _levelRuntime;
    if (native == null) throw StateError('No runtime entity.');
    return native.inspectEntity(handle);
  }

  GameRuntimeSnapshot snapshot() {
    final scene = _scene, simulation = _simulation, project = _project;
    if (scene == null || simulation == null || project == null) {
      throw StateError('No runtime snapshot.');
    }
    final records = project.levels
        .singleWhere((l) => l.id == simulation.session.levelId)
        .entities;
    return GameRuntimeSnapshot(
      buildId: project.buildId,
      tick: tick,
      entities: [
        for (final record in records)
          if (record.nodeId != null && scene.objects.containsKey(record.nodeId))
            GameRuntimeEntitySnapshot(
              nodeId: record.nodeId!,
              position: scene.objects[record.nodeId]!.position,
              rotation: scene.objects[record.nodeId]!.quaternion,
              scale: scene.objects[record.nodeId]!.scale,
              components: {
                for (final component in record.components)
                  component.type: component.data,
              },
            ),
      ],
    );
  }

  Future<void> stop() {
    final stopping = _stopping;
    if (stopping != null) return stopping;
    final result = _stop();
    _stopping = result;
    result.then<void>(
      (_) {
        if (identical(_stopping, result)) _stopping = null;
      },
      onError: (Object _, StackTrace _) {
        if (identical(_stopping, result)) _stopping = null;
      },
    );
    return result;
  }

  Future<void> _stop() async {
    ++_generation;
    _cancel?.cancel();
    try {
      await _launching;
    } catch (_) {}
    try {
      await _disposeResources();
    } finally {
      _state = GamePlayState.stopped;
      _publish();
    }
  }

  Future<void> _disposeResources() async {
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

    await cleanup(() async {
      final controller = _controller;
      _controller = null;
      if (controller != null) {
        controller.dispose();
        await controller.whenDisposed;
      }
      final engine = _fixtureEngine;
      _fixtureEngine = null;
      await engine?.dispose();
    });
    final native = _levelRuntime;
    await cleanup(() async {
      final prepared = _preparedRuntime;
      _preparedRuntime = null;
      await prepared?.close();
    });
    await cleanup(() async {
      await native?.close();
    });
    _levelRuntime = null;
    if (native?.resourcesAdopted != true) {
      await cleanup(() => _audio?.close());
      await cleanup(() async {
        await _models?.close();
      });
      await cleanup(() async {
        await _assets?.close();
      });
    }
    _audio = null;
    _models = null;
    _assets = null;
    _scene = null;
    if (identical(_playOwners[authoredScene], this)) {
      _playOwners[authoredScene] = null;
    }
    if (first != null) Error.throwWithStackTrace(first!, trace!);
  }

  @override
  Future<void> close() => stop();
  @override
  void dispose() {
    if (_simulation != null || _launching != null) {
      throw StateError('Await stop before disposing play notifications.');
    }
    _disposed = true;
    super.dispose();
  }
}
