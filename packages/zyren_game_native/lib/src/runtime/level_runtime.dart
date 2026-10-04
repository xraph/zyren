part of '../../runtime.dart';

final _levelRuntimeOwners = Expando<GameLevelRuntime>('native level runtime');

/// Hosts transfer these resources once; native simulation closes before them.
final class GameRuntimeResourceLease {
  final FutureOr<void> Function() _close;
  final void Function()? _pause, _resume;
  Future<void>? _closing;
  GameLevelRuntime? _owner;
  GameRuntimeResourceLease({
    required FutureOr<void> Function() close,
    void Function()? pause,
    void Function()? resume,
  }) : _close = close,
       _pause = pause,
       _resume = resume;
  void pause() {
    if (_closing == null) _pause?.call();
  }

  void resume() {
    if (_closing == null) _resume?.call();
  }

  Future<void> close() => _closing ??= Future<void>.sync(_close);
}

final class GameCharacterAnimation {
  final CharacterMotor motor;
  final List<ScenePlugin> plugins;
  GameCharacterAnimation(this.motor, {required List<ScenePlugin> plugins})
    : plugins = List.unmodifiable(plugins);
}

typedef GameCharacterAnimationFactory =
    GameCharacterAnimation? Function(
      GameEntityRecord entity,
      Object3D root,
      PhysicsBody body,
      PhysicsCollider collider,
    );

/// Borrows the host scene; owns its native bodies, systems and transferred leases.
final class GameLevelRuntime {
  final CompiledGameProject project;
  final Scene scene;
  final Camera camera;
  final Map<String, Object3D> _objects;
  Map<String, Object3D> get objects => UnmodifiableMapView(_objects);
  final _spawnValidators = <void Function(List<GameEntityRecord>)>[];
  GameEntityRecord? entityDefinition(String id) =>
      _closed ? null : _records[id];
  final _records = <String, GameEntityRecord>{};
  final _spawnSlots = <String, GameRuntimeSpawnInstance>{};
  final _recordSlots = <String, GameRuntimeSpawnInstance>{};
  final _spawnPreparations = <Future<GameRuntimeSpawnInstance>>{};
  final _preparingSpawnIds = <String>{};
  final _topologyListeners = <void Function(GameRuntimeTopologyChange)>[];
  final int maxPreparedSpawns;
  int get spawnPoolSize => _spawnSlots.length;
  final int seed;
  final Set<String> capabilities;
  final GameCharacterAnimationFactory? animationFactory;
  final List<GameSystem> Function(GameLevelRuntime)? systemFactory;
  final void Function()? onChanged;
  final List<GameRuntimeResourceLease> resources;
  bool _adopted = false,
      _closed = false,
      _initializing = false,
      _resourcesPaused = false;
  Future<void>? _closing;
  bool get resourcesAdopted => _adopted;
  bool get isClosed => _closed;
  GameSimulation? _simulation;
  GameSimulation? get simulation => _simulation;
  Object? get error => _checkpointFault ?? _simulation?.session.fault;
  Object? _checkpointFault;
  bool _restoringCheckpoint = false, _setupReady = false;
  _NativeLevelState? _restoredNative;
  final _actorRegistrations = <void Function()>[];
  final _restoredListeners = <void Function()>[];
  final _active = <String, bool>{};
  final _actorControls = <GameEntityHandle, GameRuntimeActorControl>{};
  final _primitiveIntents = <GameEntityHandle, CharacterIntent>{};
  int _nextActorControl = 0;
  GameRuntimeActorControl? acquireActorControl(GameEntityHandle actor) =>
      _acquireActorControl(this, actor);
  bool isEntityActive(GameEntityHandle actor) =>
      !_closed &&
      _simulation?.session.entities.isAlive(actor) == true &&
      _active[actor.id] != false;
  PhysicsCollider? resolveCollider(GameEntityHandle actor) =>
      resolveBody(actor) == null ? null : _colliders[actor.id];
  bool? actorGrounded(GameEntityHandle actor) {
    if (resolveBody(actor) == null) return null;
    return _characters[actor]?.grounded ??
        _primitiveCharacters[actor]?.grounded ??
        (_vehicleControllers[actor] == null
            ? null
            : _vehicleControllers[actor]!.telemetry.groundedWheels > 0);
  }

  void _releaseActorControls() {
    for (final control in _actorControls.values.toList()) {
      control.dispose();
    }
    _primitiveIntents.clear();
  }

  GameSave save() => _saveRuntime(this);
  void restore(GameSave save) => _restoreRuntime(this, save);
  Registration listenRestored(void Function() callback) {
    if (_closed || _restoredListeners.length >= 1024) {
      throw StateError('Restore listener unavailable.');
    }
    _restoredListeners.add(callback);
    return Registration(() => _restoredListeners.remove(callback));
  }

  GameLevelRuntime({
    required this.project,
    required this.scene,
    required this.camera,
    required Map<String, Object3D> objects,
    this.seed = 1,
    this.maxPreparedSpawns = 64,
    Set<String> capabilities = const {},
    this.animationFactory,
    this.systemFactory,
    this.onChanged,
    List<GameRuntimeResourceLease> resources = const [],
  }) : _objects = Map.of(objects),
       capabilities = Set.unmodifiable(capabilities),
       resources = List.unmodifiable(resources) {
    if (maxPreparedSpawns < 1 || maxPreparedSpawns > 256) {
      throw ArgumentError(
        'Prepared native spawn pool must contain 1..256 slots.',
      );
    }
  }
  void _publish() {
    if (!_closed && !_restoringCheckpoint) onChanged?.call();
  }

  GameCharacterMotorRegistry? _motors;
  GameVehicleSystem? _vehicles;
  final _registrations = <void Function()>[];
  final _bodies = <String, PhysicsBody>{};
  final _colliders = <String, PhysicsCollider>{};
  final _shapes = <String, ColliderShape>{};
  final _animations = <String, GameCharacterAnimation>{};
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
  bool get isPaused => _simulation?.session.paused ?? false;
  List<ScenePlugin> get plugins {
    if (_closed || _simulation == null) {
      throw StateError('Initialize the level runtime first.');
    }
    return List.unmodifiable([
      for (final animation in _animations.values) ...animation.plugins,
      _simulation!.physics,
      GameScenePlugin(_simulation!),
    ]);
  }

  Future<void> initialize() async {
    if (_closed ||
        _initializing ||
        _simulation != null ||
        _levelRuntimeOwners[scene] != null) {
      throw StateError('The scene already has a runtime owner.');
    }
    if (project.fixedHz < 10) {
      throw ArgumentError('Native game rates must be within 10..240 Hz.');
    }
    if (!capabilities.containsAll(project.capabilityRequirements)) {
      throw UnsupportedError('Missing game capabilities.');
    }
    final level = project.levels.singleWhere(
      (l) => l.id == project.project.startupLevel,
    );
    if (resources.toSet().length != resources.length ||
        resources.any((r) => r._owner != null || r._closing != null)) {
      throw ArgumentError(
        'Resource leases must be fresh and transferred once.',
      );
    }
    _records.addAll({for (final entity in level.entities) entity.id: entity});
    _initializing = true;
    _levelRuntimeOwners[scene] = this;
    for (final resource in resources) {
      resource._owner = this;
    }
    _adopted = true;
    try {
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
            _PrimitiveControllers(this),
            GameVehiclePresentationSystem(_vehicles!),
            _PlayCamera(this),
            _RuntimeResources(this),
            ...?(systemFactory?.call(this)),
          ],
        );
        _registrations.add(
          _simulation!.session
              .registerStateCodec(_NativeLevelCodec(this))
              .cancel,
        );
        _registrations.add(_motors!.connect(_simulation!).dispose);
        _registrations.add(
          _simulation!.session.listenState(_syncResourceState).cancel,
        );
        for (final entity in level.entities) {
          _createNativeEntity(entity);
        }
        // A collision query refreshes authored mass and query proxies without
        // advancing Rapier. Vehicle forces must not depend on a prior motor query.
        if (_bodies.isNotEmpty) {
          world.rayCast(
            origin: Vec3.zero,
            direction: const Vec3(0, 1, 0),
            maxDistance: .001,
          );
        }
        for (final entity in level.entities) {
          if (!entity.components.any((c) => c.type == 'game.vehicle') &&
              !_animations.containsKey(entity.id)) {
            final body = _bodies[entity.id], root = objects[entity.nodeId];
            if (body != null && root != null) physics.bind(root, body);
          }
        }
      } catch (_) {
        if (_simulation == null && !world.isClosed) world.close();
        rethrow;
      }
    } catch (error, stack) {
      try {
        await close();
      } catch (_) {
        /* Preserve the initialization error. */
      }
      Error.throwWithStackTrace(error, stack);
    } finally {
      _initializing = false;
    }
  }

  void _createNativeEntity(GameEntityRecord entity) {
    final world = this.world!;
    final record = entity.components
        .where((c) => c.type == 'game.collider')
        .firstOrNull;
    if (record == null) return;
    final definition = GameColliderDefinition.fromJson(record.data);
    final root = objects[entity.nodeId];
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
      throw StateError('Native collider nodes require positive uniform scale.');
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
    _bodies[entity.id] = body;
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
    _colliders[entity.id] = collider;
    _shapes[entity.id] = shape;

    final char = entity.components
        .where((c) => c.type == 'game.character')
        .firstOrNull;
    if (char != null) {
      if (definition.motion != GameBodyMotion.kinematic ||
          definition.shape != GameColliderShape.capsule) {
        throw StateError('Characters require an authored kinematic capsule.');
      }
      final animation = animationFactory?.call(entity, root, body, collider);
      if (animation != null) _animations[entity.id] = animation;
      if (animation != null &&
          (!identical(animation.motor.controller.body, body) ||
              !identical(animation.motor.controller.collider, collider))) {
        throw StateError('CharacterMotor must use this authored capsule.');
      }
      if (_containsModel(root) && animation == null) {
        throw StateError(
          'Imported characters need an actual CharacterMotor factory.',
        );
      }
    }
  }

  void pause() {
    final simulation = _simulation;
    if (_checkpointFault != null) throw StateError('Native restore failed.');
    if (_closed || simulation == null || simulation.session.paused) {
      throw StateError('The level is not running.');
    }
    simulation.session.pause();
    _publish();
  }

  void resume() {
    if (_checkpointFault != null) throw StateError('Native restore failed.');
    if (!isPaused || _closed) throw StateError('Pause before resuming.');
    _simulation!.session.resume();
    _restoreControl();
    _publish();
  }

  void step() {
    if (_checkpointFault != null) throw StateError('Native restore failed.');
    if (!isPaused || _closed) throw StateError('Pause before stepping.');
    final session = _simulation!.session;
    try {
      session.resume();
      _restoreControl();
      session.step();
    } finally {
      if (!session.isClosed && session.fault == null) session.pause();
      _publish();
    }
  }

  void _restoreControl() {
    final intended = _controlled;
    if (intended != null && controlEntity(intended)) return;
    if (_inputActor != null && controlEntity(_inputActor)) return;
    _controlled = null;
  }

  PhysicsBody? resolveBody(GameEntityHandle handle) =>
      _simulation?.session.entities.isAlive(handle) == true
      ? _bodies[handle.id]
      : null;

  /// Changes runtime visibility and collision only for a current authored entity.
  void setEntityActive(GameEntityHandle handle, bool active) {
    final entity = _simulation?.session.entities.entity(handle);
    if (entity == null) throw StateError('Entity is no longer alive.');
    final authored = _records[handle.id]!;
    final nodeId = authored.nodeId;
    final root = nodeId == null ? null : objects[nodeId];
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
    _active[handle.id] = active;
    if (!active) _actorControls[handle]?.dispose();

    if (!_restoringCheckpoint) _publish();
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

  void _syncResourceState() {
    if (_closed) return;
    final session = _simulation!.session;
    _setResourcesPaused(
      session.paused || session.fault != null || session.isClosed,
    );
    _publish();
  }

  void _setResourcesPaused(bool paused) {
    if (_resourcesPaused == paused) return;
    _resourcesPaused = paused;
    Object? first;
    StackTrace? trace;
    for (final resource in [
      ...resources,
      for (final slot in _spawnSlots.values.where((s) => s.isActive)) ...[
        ...slot._source.resources,
        ?slot._pluginLease,
      ],
    ]) {
      try {
        if (paused) {
          resource.pause();
        } else {
          resource.resume();
        }
      } catch (error, stack) {
        first ??= error;
        trace ??= stack;
      }
    }
    if (first != null) Error.throwWithStackTrace(first, trace!);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _releaseActorControls();
    Object? first;
    StackTrace? trace;
    Future<void> cleanup(FutureOr<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stack) {
        first ??= error;
        trace ??= stack;
      }
    }

    await cleanup(() async {
      for (final preparation in _spawnPreparations.toList()) {
        try {
          await preparation;
        } catch (_) {}
      }
    });
    for (final slot in _spawnSlots.values) {
      slot._cancelQueued();
    }
    for (final input in _inputs.values) {
      input.releaseEveryDevice();
    }
    for (final registration in _actorRegistrations.reversed) {
      await cleanup(registration);
    }
    _actorRegistrations.clear();
    _restoredListeners.clear();
    _topologyListeners.clear();
    _spawnValidators.clear();
    for (final registration in _registrations.reversed) {
      await cleanup(registration);
    }
    _registrations.clear();
    final simulation = _simulation;
    _simulation = null;
    await cleanup(() async {
      await simulation?.close();
    });
    final staged = _stagingWorld;
    _stagingWorld = null;
    if (staged != null && !staged.isClosed) await cleanup(staged.close);
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
    _controlled = null;
    _selection = null;
    _inputActor = null;
    _possession = null;
    _characterLeases.clear();
    _vehicleLeases.clear();
    for (final slot in _spawnSlots.values.toList().reversed) {
      _removeSpawnNative(slot);
      await cleanup(() => slot._closeResources());
    }
    _spawnSlots.clear();
    _recordSlots.clear();
    if (_adopted) {
      for (final resource in resources.reversed) {
        await cleanup(resource.close);
      }
    }
    if (identical(_levelRuntimeOwners[scene], this)) {
      _levelRuntimeOwners[scene] = null;
    }
    if (first != null) Error.throwWithStackTrace(first!, trace!);
  }
}

final class _RuntimeResources extends GameSystem {
  final GameLevelRuntime owner;
  _RuntimeResources(this.owner);
  @override
  String get id => 'game.runtime-resources';
  @override
  GamePhase get phase => GamePhase.diagnostics;
  @override
  void fixedUpdate(GameSession session) {}
  @override
  void pause(GameSession session) => owner._setResourcesPaused(true);
  @override
  void resume(GameSession session) => owner._setResourcesPaused(false);
}

final class _PrimitiveCharacter {
  final KinematicCharacterController controller;
  final GameCharacterDefinition definition;
  double verticalSpeed = 0;
  bool grounded = false;
  _PrimitiveCharacter(this.controller, this.definition);
  void advance(CharacterIntent intent, double seconds) {
    var direction = Quat.axisAngle(
      const Vec3(0, 1, 0),
      intent.lookYaw,
    ).rotate(Vec3(intent.moveX, 0, intent.moveZ));
    if (direction.length > 1) direction = direction.normalized();
    if (intent.jump && grounded) {
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
  final GameLevelRuntime owner;
  _PlaySetup(this.owner);
  @override
  String get id => 'game.play-setup';
  @override
  GamePhase get phase => GamePhase.controllers;
  @override
  Set<String> get dependencies => {'game.vehicles'};
  @override
  void start(GameSession session) => bind(session);
  void bind(GameSession session, {bool restoring = false}) {
    final level = session.project.levels.singleWhere(
      (l) => l.id == session.levelId,
    );
    final handles = {
      for (final e in session.entities.entities) e.handle.id: e.handle,
    };
    for (final entity in owner._records.values) {
      final handle = handles[entity.id];
      if (handle == null) continue;
      bindController(
        session,
        entity,
        handle,
        (callback) => owner._registerActor(entity.id, callback),
      );
    }
    owner._possession = GamePossession(
      session,
      maxSeats: math.min(1024, session.entities.limits.maxEntities),
    );
    owner._actorRegistrations.add(owner._possession!.close);
    for (final target in {
      ...owner._primitiveCharacters.keys,
      ...owner._characters.keys,
      ...owner._vehicleControllers.keys,
    }) {
      bindSeat(
        session,
        target,
        (callback) => owner._registerActor(target.id, callback),
      );
    }

    if (!restoring && owner._inputActor != null) {
      owner.controlEntity(owner._inputActor);
    }
    for (final entity in level.entities) {
      for (final camera in entity.components.where(
        (c) => c.type == 'game.camera',
      )) {
        final rig = GameCameraRig.fromDefinition(
          camera: owner.camera,
          session: session,
          world: owner._simulation!.world,
          resolveBody: owner.resolveBody,
          definition: GameCameraDefinition.fromJson(camera.data),
        );
        owner._cameras.add(rig);
        owner._cameraModes[rig] = rig.mode;
      }
    }
    owner._setupReady = true;
  }

  void bindController(
    GameSession session,
    GameEntityRecord entity,
    GameEntityHandle handle,
    void Function(void Function()) register,
  ) {
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
        register(
          owner._motors!
              .register(controller, owner.objects[entity.nodeId]!)
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
          root = owner.objects[entity.nodeId]!;
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
      register(() {
        for (final visual in visuals) {
          root.remove(visual);
        }
      });
      final controller = VehicleController(
        session: session,
        actor: handle,
        body: body,
        definition: definition,
      );
      owner._vehicleControllers[handle] = controller;
      register(
        owner._vehicles!
            .register(controller, presentationRoot: root, wheelVisuals: visuals)
            .dispose,
      );
    }
  }

  void bindSeat(
    GameSession session,
    GameEntityHandle target,
    void Function(void Function()) register,
  ) {
    register(
      owner._possession!
          .registerSeat(
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
                return body != null &&
                    owner.exitPlacement(actor, target) != null;
              },
              acquireControl: (actor) {
                owner._actorControls[target]?.dispose();
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
          )
          .dispose,
    );
  }

  @override
  void fixedUpdate(GameSession session) {}
}

final class _PlayInput extends GameSystem {
  final GameLevelRuntime owner;
  _PlayInput(this.owner);
  @override
  String get id => 'game.play-input';
  @override
  GamePhase get phase => GamePhase.commands;
  @override
  void fixedUpdate(GameSession session) {
    for (final actor in owner._primitiveCharacters.keys) {
      if (actor != owner._controlled) continue;
      final input =
          owner._inputActor != null &&
              owner._possession?.seatOf(owner._inputActor!) == actor.id
          ? owner.actions
          : null;
      owner._primitiveIntents[actor] = CharacterIntent(
        moveX: _actionAxis(input, 'move.x'),
        moveZ: _actionAxis(input, 'move.z'),
        jump: _actionPressed(input, 'jump'),
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
    owner._releaseActorControls();
    for (final input in owner._inputs.values) {
      input.releaseEveryDevice();
    }
    if (owner._checkpointFault != null) {
      throw StateError('Native restore failed: ${owner._checkpointFault}');
    }
  }

  @override
  void resume(GameSession session) {
    if (owner._checkpointFault != null) {
      throw StateError('Native restore failed: ${owner._checkpointFault}');
    }
  }
}

final class _PlayCamera extends GameSystem {
  final GameLevelRuntime owner;
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
