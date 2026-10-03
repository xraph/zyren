part of '../../play.dart';

final _playOwners = Expando<GamePlaySession>('Studio play owner');

enum GamePlayState { stopped, loading, running, paused, failed }

/// The host builds this from the loaded imported model. Animation has one clock.
final class GamePlayCharacterAnimation {
  final CharacterMotor motor;
  final List<ScenePlugin> plugins;
  GamePlayCharacterAnimation(this.motor, {required List<ScenePlugin> plugins})
    : plugins = List.unmodifiable(plugins);
}

typedef GamePlayAnimationFactory =
    GamePlayCharacterAnimation? Function(
      GameEntityRecord entity,
      Object3D root,
      PhysicsBody body,
      PhysicsCollider collider,
    );

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
  GameSimulation? _simulation;
  GameSimulation? get simulation => _simulation;
  SceneController? _controller;
  SceneController? get controller => _controller;
  SceneEngine? _fixtureEngine;
  GameCharacterMotorRegistry? _motors;
  GameVehicleSystem? _vehicles;
  final _registrations = <void Function()>[];
  final _bodies = <String, PhysicsBody>{};
  final _colliders = <String, PhysicsCollider>{};
  final _shapes = <String, ColliderShape>{};
  final _animations = <String, GamePlayCharacterAnimation>{};
  final _characters = <GameEntityHandle, GameCharacterController>{};
  final _primitiveCharacters = <GameEntityHandle, _PrimitiveCharacter>{};
  final _vehicleControllers = <GameEntityHandle, VehicleController>{};
  final _inputs = <GameEntityHandle, GameActionState>{};
  final _cameras = <GameCameraRig>[];
  final _cameraModes = <GameCameraRig, GameCameraMode>{};
  PhysicsWorld? _stagingWorld;
  PhysicsWorld? get world => _simulation?.world ?? _stagingWorld;
  GameEntityHandle? _controlled, _selection, _inputActor;
  GamePossession? _possession;
  final _characterLeases = <GameEntityHandle, GameCharacterControlLease>{};
  final _vehicleLeases = <GameEntityHandle, VehicleControlLease>{};
  GamePossession? get possession => _possession;
  GameEntityHandle? get controlledActor => _controlled;
  GameEntityHandle? get inputActor => _inputActor;
  Map<GameEntityHandle, GameCharacterController> get animatedCharacters =>
      Map.unmodifiable(_characters);
  Map<GameEntityHandle, VehicleController> get vehicles =>
      Map.unmodifiable(_vehicleControllers);
  GameActionState? get actions => _inputs[_inputActor];
  bool controlEntity(GameEntityHandle? target) {
    final actor = _inputActor, host = _possession;
    if (actor == null ||
        host == null ||
        target != null &&
            _simulation?.session.entities.isAlive(target) != true) {
      return false;
    }
    final previous = _controlled;
    final exiting =
        previous != null &&
        previous != target &&
        _vehicleControllers.containsKey(previous);
    final exit = exiting ? exitPlacement(actor, previous) : null;
    if (exiting && exit == null) return false;
    if (!host.transfer(actor, target?.id)) return false;
    if (exiting) {
      final checked = exitPlacement(actor, previous);
      final body = resolveBody(actor);
      if (checked == null || body == null) {
        host.transfer(actor, null);
        _controlled = null;
        actions?.releaseEveryDevice();
        return false;
      }
      body.teleport(checked);
    }
    actions?.releaseEveryDevice();
    _controlled = target;
    for (final camera in _cameras) {
      camera.follow(target);
      if (target != null) {
        camera.mode = _vehicleControllers.containsKey(target)
            ? GameCameraMode.vehicle
            : _cameraModes[camera]!;
      }
    }
    _publish();
    return true;
  }

  /// A current native capsule query validates the driver's exit after driving.
  PhysicsPose? exitPlacement(GameEntityHandle actor, GameEntityHandle vehicle) {
    final body = resolveBody(vehicle), shape = _shapes[actor.id];
    if (body == null || shape is! CapsuleShape) return null;
    final pose = body.state.pose;
    final origin = pose.position + pose.rotation.rotate(const Vec3(1.6, 3, 0));
    final ground = body.world.rayCast(
      origin: origin,
      direction: const Vec3(0, -1, 0),
      maxDistance: 5,
      filter: QueryFilter(excludeBody: body, excludeSensors: true),
    );
    if (ground == null || ground.normal.y < .7) return null;
    final groundY = origin.y - ground.time;
    if (groundY > pose.position.y + .5) return null;
    final candidate = PhysicsPose(
      position: Vec3(
        origin.x,
        groundY + shape.halfHeight + shape.radius + .02,
        origin.z,
      ),
      rotation: pose.rotation,
    );
    final ownCollider = _colliders[actor.id]?.id;
    if (body.world
        .overlap(
          shape: shape,
          pose: candidate,
          filter: QueryFilter(excludeBody: body, excludeSensors: true),
        )
        .any((id) => id != ownCollider)) {
      return null;
    }
    return candidate;
  }

  GameEntityHandle? get runtimeSelection => _selection;
  set runtimeSelection(GameEntityHandle? value) {
    final session = _simulation?.session;
    if (value != null &&
        (session == null || !session.entities.isAlive(value))) {
      throw StateError('Runtime selection is no longer alive.');
    }
    _selection = value;
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
      final world = PhysicsWorld(fixedStep: 1 / project.fixedHz);
      _stagingWorld = world;
      try {
        _motors = GameCharacterMotorRegistry(world);
        final physics = PhysicsPlugin(
          world: world,
          externallyDriven: true,
          interpolate: false,
          maxFrameDelta: 1 / project.fixedHz,
          beforeStep: _motors!.advance,
        );
        _vehicles = GameVehicleSystem(world: world, physics: physics);
        _simulation = GameSimulation(
          project: project,
          seed: seed,
          physics: physics,
          ownsWorld: true,
          availableCapabilities: capabilities,
          systems: [
            _vehicles!,
            _PlaySetup(this),
            _PlayInput(this),
            GameVehiclePresentationSystem(_vehicles!),
            _PlayCamera(this),
            ...?(systemFactory?.call(this)),
          ],
        );
        _registrations.add(_motors!.connect(_simulation!).dispose);
        for (final entity in level.entities) {
          final record = entity.components
              .where((c) => c.type == 'game.collider')
              .firstOrNull;
          if (record == null) continue;
          final definition = GameColliderDefinition.fromJson(record.data);
          final root = _scene!.objects[entity.nodeId];
          if (root == null) throw StateError('Collider node is missing.');
          final matrix = root.worldMatrix.toVectorMath();
          final position = Vec3.fromVectorMath(matrix.getTranslation());
          // Collider dimensions are local metres. Uniform scale is applied once.
          final scale = matrix.getMaxScaleOnAxis();
          final lengths = [
            for (var axis = 0; axis < 3; axis++)
              math.sqrt(
                matrix.entry(0, axis) * matrix.entry(0, axis) +
                    matrix.entry(1, axis) * matrix.entry(1, axis) +
                    matrix.entry(2, axis) * matrix.entry(2, axis),
              ),
          ];
          if (lengths.any((v) => (v - scale).abs() > 1e-6) || scale <= 0) {
            throw StateError(
              'Native collider nodes require positive uniform scale.',
            );
          }
          for (Object3D? node = root; node != null; node = node.parent) {
            if (node.scale.storage.any((v) => v <= 0)) {
              throw StateError(
                'Mirrored native collider transforms are unsupported.',
              );
            }
          }
          for (var a = 0; a < 3; a++) {
            for (var b = a + 1; b < 3; b++) {
              var dot = 0.0;
              for (var row = 0; row < 3; row++) {
                dot += matrix.entry(row, a) * matrix.entry(row, b);
              }
              if (dot.abs() > 1e-6 * scale * scale) {
                throw StateError(
                  'Sheared native collider transforms are unsupported.',
                );
              }
            }
          }
          var rotation = Quat.identity;
          for (Object3D? node = root; node != null; node = node.parent) {
            rotation = node.quaternion * rotation;
          }
          final vehicleRecord = entity.components
              .where((c) => c.type == 'game.vehicle')
              .firstOrNull;
          final mass = vehicleRecord == null
              ? definition.mass
              : VehicleDefinition.fromJson(vehicleRecord.data).mass;
          final body = world.createBody(
            kind: switch (definition.motion) {
              GameBodyMotion.fixed => BodyKind.fixed,
              GameBodyMotion.dynamic => BodyKind.dynamic,
              GameBodyMotion.kinematic => BodyKind.kinematicPosition,
            },
            pose: PhysicsPose(position: position, rotation: rotation),
            mass: definition.motion == GameBodyMotion.dynamic ? mass : null,
            ccd: definition.motion == GameBodyMotion.dynamic,
          );
          final shape = switch (definition.shape) {
            GameColliderShape.box => BoxShape(definition.halfExtents * scale),
            GameColliderShape.capsule => CapsuleShape(
              halfHeight: definition.halfHeight * scale,
              radius: definition.radius * scale,
            ),
            GameColliderShape.sphere => SphereShape(definition.radius * scale),
          };
          final collider = body.addCollider(
            shape,
            density: 0,
            friction: definition.friction,
            restitution: definition.restitution,
            sensor: definition.sensor,
          );
          _bodies[entity.id] = body;
          _colliders[entity.id] = collider;
          _shapes[entity.id] = shape;

          final char = entity.components
              .where((c) => c.type == 'game.character')
              .firstOrNull;
          if (char != null) {
            if (definition.motion != GameBodyMotion.kinematic ||
                definition.shape != GameColliderShape.capsule) {
              throw StateError(
                'Characters require an authored kinematic capsule.',
              );
            }
            final animation = animationFactory?.call(
              entity,
              root,
              body,
              collider,
            );
            if (animation != null) _animations[entity.id] = animation;
            if (animation != null &&
                (!identical(animation.motor.controller.body, body) ||
                    !identical(
                      animation.motor.controller.collider,
                      collider,
                    ))) {
              throw StateError(
                'CharacterMotor must use this authored capsule.',
              );
            }
            if (_containsModel(root) && animation == null) {
              throw StateError(
                'Imported characters need an actual CharacterMotor factory.',
              );
            }
          }
        }
        for (final entity in level.entities) {
          if (!entity.components.any((c) => c.type == 'game.vehicle') &&
              !_animations.containsKey(entity.id)) {
            final body = _bodies[entity.id],
                root = _scene!.objects[entity.nodeId];
            if (body != null && root != null) physics.bind(root, body);
          }
        }
        _audio = audioFactory?.call(_scene!);
        final session = _simulation!.session;
        _registrations.add(
          session.listenState(() {
            if (session.fault != null) {
              error = session.fault;
              _state = GamePlayState.failed;
            } else if (session.paused && _state == GamePlayState.running) {
              _state = GamePlayState.paused;
            }
            if (session.paused || session.fault != null) {
              _audio?.suspend();
              for (final actions in _inputs.values) {
                actions.releaseEveryDevice();
              }
            }
            _publish();
          }).cancel,
        );
        final plugins = <ScenePlugin>[
          for (final a in _animations.values) ...a.plugins,
          physics,
          GameScenePlugin(_simulation!),
        ];
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
        _state = GamePlayState.running;
        _publish();
      } catch (_) {
        if (_simulation == null && !world.isClosed) world.close();
        rethrow;
      }
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
    _requireRunning();
    _simulation!.session.pause();
    for (final state in _inputs.values) {
      state.releaseEveryDevice();
    }
    _audio?.suspend();
    _state = GamePlayState.paused;
    _publish();
  }

  @override
  void resume() {
    if (!isPaused) throw StateError('Pause before resuming.');
    _simulation!.session.resume();
    _restoreControl();
    _audio?.resume();
    _state = GamePlayState.running;
    _publish();
  }

  @override
  void step() {
    if (!isPaused) throw StateError('Pause before stepping.');
    final session = _simulation!.session;
    try {
      session.resume();
      _restoreControl();
      session.step();
    } finally {
      if (!session.isClosed && session.fault == null) session.pause();
      _audio?.suspend();
      _publish();
    }
  }

  void _restoreControl() {
    final intended = _controlled;
    if (intended != null && controlEntity(intended)) return;
    if (_inputActor != null && controlEntity(_inputActor)) return;
    _controlled = null;
  }

  void _requireRunning() {
    if (_state != GamePlayState.running || _simulation == null) {
      throw StateError('The play session is not running.');
    }
  }

  PhysicsBody? resolveBody(GameEntityHandle handle) =>
      _simulation?.session.entities.isAlive(handle) == true
      ? _bodies[handle.id]
      : null;

  /// Changes runtime visibility and collision only for a current authored entity.
  void setEntityActive(GameEntityHandle handle, bool active) {
    final entity = _simulation?.session.entities.entity(handle);
    if (entity == null) throw StateError('Entity is no longer alive.');
    final authored = _project!.levels
        .singleWhere((l) => l.id == _simulation!.session.levelId)
        .entities
        .singleWhere((e) => e.id == handle.id);
    final nodeId = authored.nodeId, scene = _scene;
    final root = nodeId == null ? null : scene?.objects[nodeId];
    if (root == null) throw StateError('Entity has no authored runtime node.');
    final collider = _colliders[handle.id];
    if (collider != null) {
      final record = entity.components.singleWhere(
        (c) => c.type == 'game.collider',
      );
      final definition = GameColliderDefinition.fromJson(record.data);
      collider.configure(
        friction: definition.friction,
        restitution: definition.restitution,
        density: 0,
        sensor: active ? definition.sensor : true,
        membership: active ? 0xffffffff : 0,
        filter: active ? 0xffffffff : 0,
      );
    }
    root.visible = active;
    _controller?.invalidate();
    _publish();
  }

  Map<String, Object?> inspectEntity(GameEntityHandle handle) {
    final session = _simulation?.session;
    if (session == null || !session.entities.isAlive(handle)) {
      throw StateError('Entity is no longer alive.');
    }
    final body = resolveBody(handle), vehicle = _vehicleControllers[handle];
    return Map.unmodifiable({
      'actor': handle.toString(),
      'tick': tick,
      'epoch': session.epoch,
      'components': session.entities
          .entity(handle)!
          .components
          .map((c) => c.toJson())
          .toList(),
      'controller': _characters.containsKey(handle)
          ? 'animated'
          : _primitiveCharacters.containsKey(handle)
          ? 'primitive'
          : vehicle != null
          ? 'vehicle'
          : 'entity',
      if (body != null) 'position': body.state.pose.position.storage,
      if (body != null) 'velocity': body.state.velocity.storage,
      if (vehicle != null)
        'wheels': vehicle.telemetry.wheels
            .map((w) => {'contact': w.contact, 'normalLoad': w.normalLoad})
            .toList(),
    });
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
    await _disposeResources();
    _state = GamePlayState.stopped;
    _publish();
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

    for (final input in _inputs.values) {
      input.releaseEveryDevice();
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
    for (final registration in _registrations.reversed) {
      await cleanup(registration);
    }
    _registrations.clear();
    await cleanup(() async {
      final simulation = _simulation;
      _simulation = null;
      await simulation?.close();
    });
    await cleanup(() {
      _audio?.close();
      _audio = null;
    });
    await cleanup(() async {
      final models = _models;
      _models = null;
      await models?.close();
    });
    await cleanup(() async {
      final assets = _assets;
      _assets = null;
      await assets?.close();
    });
    _scene = null;
    _motors = null;
    _vehicles = null;
    _bodies.clear();
    _colliders.clear();
    _shapes.clear();
    _animations.clear();
    _characters.clear();
    _primitiveCharacters.clear();
    _vehicleControllers.clear();
    _inputs.clear();
    _cameras.clear();
    _cameraModes.clear();
    _stagingWorld = null;
    _controlled = null;
    _selection = null;
    _inputActor = null;
    _possession = null;
    _characterLeases.clear();
    _vehicleLeases.clear();
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

final class _PrimitiveCharacter {
  final KinematicCharacterController controller;
  final GameCharacterDefinition definition;
  double verticalSpeed = 0;
  bool grounded = false;
  _PrimitiveCharacter(this.controller, this.definition);
  void advance(GameActionState? input, double seconds) {
    var direction = Vec3(
      _actionAxis(input, 'move.x'),
      0,
      _actionAxis(input, 'move.z'),
    );
    if (direction.length > 1) direction = direction.normalized();
    if (_actionPressed(input, 'jump') && grounded) {
      verticalSpeed = definition.jumpSpeed;
    }
    verticalSpeed = math.max(-50, verticalSpeed - 9.81 * seconds);
    if (grounded && verticalSpeed < 0) {
      verticalSpeed = -definition.groundStickSpeed;
    }
    final body = controller.body, pose = controller.body.state.pose;
    final move = controller.resolve(
      direction * (definition.maxSpeed * seconds) +
          Vec3(0, verticalSpeed * seconds, 0),
    );
    grounded = move.grounded;
    if (grounded && verticalSpeed < 0) verticalSpeed = 0;
    if (move.contacts.any((c) => c.normal.y < -.5) && verticalSpeed > 0) {
      verticalSpeed = 0;
    }
    body.setTarget(
      PhysicsPose(
        position: pose.position + move.translation,
        rotation: direction.length > 1e-9
            ? Quat.axisAngle(
                const Vec3(0, 1, 0),
                math.atan2(direction.x, direction.z),
              )
            : pose.rotation,
      ),
    );
  }
}

final class _PlaySetup extends GameSystem {
  final GamePlaySession owner;
  _PlaySetup(this.owner);
  @override
  String get id => 'game.play-setup';
  @override
  GamePhase get phase => GamePhase.controllers;
  @override
  Set<String> get dependencies => {'game.vehicles'};
  @override
  void start(GameSession session) {
    final level = session.project.levels.singleWhere(
      (l) => l.id == session.levelId,
    );
    final handles = {
      for (final e in session.entities.entities) e.handle.id: e.handle,
    };
    for (final entity in level.entities) {
      final handle = handles[entity.id]!;
      final input = entity.components
          .where((c) => c.type == 'game.input')
          .firstOrNull;
      if (input != null) {
        owner._inputs[handle] = GameActionState(
          GameInputMap.fromJson(input.data),
        );
        owner._inputActor ??= handle;
      }
      final character = entity.components
          .where((c) => c.type == 'game.character')
          .firstOrNull;
      if (character != null) {
        final body = owner._bodies[entity.id];
        if (body == null) throw StateError('Character collider is missing.');
        final definition = GameCharacterDefinition.fromJson(character.data),
            animation = owner._animations[entity.id];
        if (animation != null) {
          final controller = GameCharacterController(
            actor: handle,
            session: session,
            motor: animation.motor,
            definition: definition,
          );
          owner._characters[handle] = controller;
          owner._registrations.add(
            owner._motors!
                .register(controller, owner._scene!.objects[entity.nodeId]!)
                .dispose,
          );
        } else {
          owner._primitiveCharacters[handle] = _PrimitiveCharacter(
            KinematicCharacterController(
              body: body,
              collider: owner._colliders[entity.id]!,
            ),
            definition,
          );
        }
      }
      final vehicle = entity.components
          .where((c) => c.type == 'game.vehicle')
          .firstOrNull;
      if (vehicle != null) {
        final body = owner._bodies[entity.id];
        if (body == null || body.kind != BodyKind.dynamic) {
          throw StateError('Vehicle requires an authored dynamic collider.');
        }
        final definition = VehicleDefinition.fromJson(vehicle.data),
            root = owner._scene!.objects[entity.nodeId]!;
        final visuals = <Object3D>[
          for (final wheel in definition.wheels)
            root.add(
              Mesh(
                CylinderGeometry(
                  radiusTop: wheel.radius,
                  radiusBottom: wheel.radius,
                  height: wheel.radius * .6,
                ),
                StandardMaterial(color: Color3.hex(0x333333)),
                name: wheel.id,
              ),
            ),
        ];
        final controller = VehicleController(
          session: session,
          actor: handle,
          body: body,
          definition: definition,
        );
        owner._vehicleControllers[handle] = controller;
        owner._registrations.add(
          owner._vehicles!
              .register(
                controller,
                presentationRoot: root,
                wheelVisuals: visuals,
              )
              .dispose,
        );
      }
    }
    owner._possession = GamePossession(
      session,
      maxSeats: math.max(
        1,
        math.min(
          1024,
          owner._primitiveCharacters.length +
              owner._characters.length +
              owner._vehicleControllers.length,
        ),
      ),
    );
    owner._registrations.add(owner._possession!.close);
    for (final target in {
      ...owner._primitiveCharacters.keys,
      ...owner._characters.keys,
      ...owner._vehicleControllers.keys,
    }) {
      owner._possession!.registerSeat(
        GamePossessionSeat(
          id: target.id,
          target: target,
          canReach: (actor) {
            final from = owner.resolveBody(owner._controlled ?? actor),
                to = owner.resolveBody(target);
            return from != null &&
                to != null &&
                (target == actor ||
                    from.state.pose.position.distanceTo(
                          to.state.pose.position,
                        ) <=
                        3);
          },
          canExit: (actor) {
            if (!owner._vehicleControllers.containsKey(target)) return true;
            final body = owner.resolveBody(target);
            return body != null && owner.exitPlacement(actor, target) != null;
          },
          acquireControl: (actor) {
            final vehicle = owner._vehicleControllers[target];
            if (vehicle != null) {
              final lease = vehicle.acquireControl(actor);
              owner._vehicleLeases[target] = lease;
              return GamePossessionControl(
                isActive: () => lease.isActive,
                release: () {
                  lease.dispose();
                  if (identical(owner._vehicleLeases[target], lease)) {
                    owner._vehicleLeases.remove(target);
                  }
                },
              );
            }
            final character = owner._characters[target];
            if (character != null) {
              final lease = character.acquireControl();
              owner._characterLeases[target] = lease;
              return GamePossessionControl(
                isActive: () => lease.isActive,
                release: () {
                  lease.dispose();
                  if (identical(owner._characterLeases[target], lease)) {
                    owner._characterLeases.remove(target);
                  }
                },
              );
            }
            final epoch = session.epoch;
            var active = true;
            return GamePossessionControl(
              isActive: () =>
                  active &&
                  session.epoch == epoch &&
                  session.entities.isAlive(target),
              release: () => active = false,
            );
          },
        ),
      );
    }
    if (owner._inputActor != null) owner.controlEntity(owner._inputActor);
    for (final entity in level.entities) {
      for (final camera in entity.components.where(
        (c) => c.type == 'game.camera',
      )) {
        final rig = GameCameraRig.fromDefinition(
          camera: owner._scene!.camera,
          session: session,
          world: owner._simulation!.world,
          resolveBody: owner.resolveBody,
          definition: GameCameraDefinition.fromJson(camera.data),
        );
        owner._cameras.add(rig);
        owner._cameraModes[rig] = rig.mode;
      }
    }
  }

  @override
  void fixedUpdate(GameSession session) {}
}

final class _PlayInput extends GameSystem {
  final GamePlaySession owner;
  _PlayInput(this.owner);
  @override
  String get id => 'game.play-input';
  @override
  GamePhase get phase => GamePhase.commands;
  @override
  void fixedUpdate(GameSession session) {
    for (final entry in owner._primitiveCharacters.entries) {
      entry.value.advance(
        entry.key == owner._controlled &&
                owner._inputActor != null &&
                owner._possession?.seatOf(owner._inputActor!) == entry.key.id
            ? owner.actions
            : null,
        session.stepSeconds,
      );
    }
    for (final entry in owner._characters.entries) {
      final lease = owner._characterLeases[entry.key];
      if (lease == null || !lease.isActive) continue;
      final input = entry.key == owner._controlled ? owner.actions : null;
      entry.value.apply(
        CharacterIntent(
          moveX: _actionAxis(input, 'move.x'),
          moveZ: _actionAxis(input, 'move.z'),
          jump: _actionPressed(input, 'jump'),
        ),
        lease: lease,
      );
    }
    for (final entry in owner._vehicleControllers.entries) {
      final lease = owner._vehicleLeases[entry.key];
      if (lease == null || !lease.isActive) continue;
      final input = entry.key == owner._controlled ? owner.actions : null;
      final axis = _actionAxis(input, 'move.z'), gear = axis < 0 ? -1 : 1;
      final shifting = axis != 0 && gear != entry.value.telemetry.gear;
      entry.value.apply(
        VehicleIntent(
          throttle: shifting ? 0 : axis.abs(),
          steer: _actionAxis(input, 'move.x'),
          brake: input == null || shifting ? 1 : 0,
          gearRequest: gear,
        ),
        lease: lease,
      );
    }
  }

  @override
  void pause(GameSession session) {
    for (final input in owner._inputs.values) {
      input.releaseEveryDevice();
    }
  }
}

final class _PlayCamera extends GameSystem {
  final GamePlaySession owner;
  _PlayCamera(this.owner);
  @override
  String get id => 'game.play-camera';
  @override
  GamePhase get phase => GamePhase.sensors;
  @override
  void fixedUpdate(GameSession session) {
    for (final camera in owner._cameras) {
      camera.update(
        CharacterIntent(lookYaw: _actionAxis(owner.actions, 'look.yaw')),
      );
    }
    owner._publish();
  }
}

double _actionAxis(GameActionState? state, String name) =>
    state?.inputMap.actions.containsKey(name) == true ? state!.axis(name) : 0;
bool _actionPressed(GameActionState? state, String name) =>
    state?.inputMap.actions[name]?.button == true && state!.takePressed(name);

bool _containsModel(Object3D node) =>
    node is ModelInstance || node.children.any(_containsModel);
