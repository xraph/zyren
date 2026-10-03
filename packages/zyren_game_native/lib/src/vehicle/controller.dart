part of '../../zyren_game_native.dart';

final class VehicleControlLease {
  final VehicleController _owner;
  final GameEntityHandle driver;
  final int generation, epoch;
  bool _active = true;
  VehicleControlLease._(this._owner, this.driver, this.generation, this.epoch);
  bool get isActive =>
      _active &&
      identical(_owner._control, this) &&
      _owner._live &&
      _owner.session.epoch == epoch &&
      _owner.session.entities.isAlive(driver);
  void dispose() {
    if (!_active) return;
    _active = false;
    if (identical(_owner._control, this)) _owner._loseControl();
  }
}

/// Ray suspension and load-limited arcade tires feed the shared physics step.
final class VehicleController {
  final GameSession session;
  final GameEntityHandle actor;
  final PhysicsBody body;
  final VehicleDefinition definition;
  final double Function(QueryHit hit, Vec3 contact)? surfaceFriction;
  VehicleIntent _intent = const VehicleIntent();
  VehicleControlLease? _control;
  int _generation = 0,
      _epoch = 0,
      _lastTick = -1,
      _forceTicks = 0,
      _gear = 1,
      _inputVersion = 0;
  late final int _massReadyByTick;
  final List<double> _rotation;
  List<WheelTelemetry> _wheels = const [];
  late VehicleTelemetry _telemetry;
  VehicleController({
    required this.session,
    required this.actor,
    required this.body,
    required this.definition,
    this.surfaceFriction,
  }) : _rotation = List.filled(definition.wheels.length, 0) {
    if (!_live || body.state.kind != BodyKind.dynamic) {
      throw ArgumentError(
        'Vehicle needs a live dynamic chassis with authored mass.',
      );
    }
    _massReadyByTick = session.tick + 1;
    _validateMass(body.state);
    _epoch = session.epoch;
    _publish();
  }
  bool get _live =>
      !session.isClosed &&
      session.fault == null &&
      session.entities.isAlive(actor) &&
      body.isAlive;
  VehicleTelemetry get telemetry => _telemetry;
  int get forceTicks => _forceTicks;
  VehicleControlLease acquireControl(GameEntityHandle driver) {
    _requireLive();
    if (!session.entities.isAlive(driver)) {
      throw StateError('Driver is no longer alive.');
    }
    _loseControl();
    _epoch = session.epoch;
    return _control = VehicleControlLease._(
      this,
      driver,
      ++_generation,
      session.epoch,
    );
  }

  void _requireLive() {
    if (!_live || session.paused) throw StateError('Vehicle is unavailable.');
    _validateMass(body.state);
  }

  bool _validateMass(BodyState state) {
    // Rapier initializes additional mass on collision refresh or the shared step.
    if (state.mass == 0 && session.tick <= _massReadyByTick) return false;
    if ((state.mass - definition.mass).abs() >
        math.max(.01, definition.mass * .001)) {
      throw StateError('Chassis mass differs from its authored vehicle mass.');
    }
    return true;
  }

  void apply(VehicleIntent intent, {VehicleControlLease? lease}) {
    _requireLive();
    intent.validate();
    if (lease != null && (!identical(_control, lease) || !lease.isActive) ||
        lease == null && _control != null) {
      throw StateError('Vehicle input producer no longer owns control.');
    }
    _intent = intent;
    _inputVersion++;
    _epoch = session.epoch;
  }

  void _loseControl() {
    _inputVersion++;
    _control?._active = false;
    _control = null;
    _intent = VehicleIntent(brake: definition.lostControlBrake);
    _epoch = session.epoch;
  }

  void reset(PhysicsPose pose) {
    _requireLive();
    if (!pose.position.isFinite || !pose.rotation.isFinite) {
      throw ArgumentError('Invalid reset pose.');
    }
    _loseControl();
    body.teleport(pose, resetVelocity: true);
    _gear = 1;
    _wheels = const [];
    _rotation.fillRange(0, _rotation.length, 0);
    _publish();
  }

  void _forces(Map<int, BodyState> bodies) {
    if (!_live || session.paused || _lastTick == session.tick) return;
    _lastTick = session.tick;
    if (_epoch != session.epoch || _control != null && !_control!.isActive) {
      _loseControl();
    }
    final state = body.state;
    if (!_validateMass(state)) return;
    final seconds = session.stepSeconds;
    final rotation = state.pose.rotation;
    final up = rotation.rotate(const Vec3(0, 1, 0));
    final forward = rotation.rotate(const Vec3(0, 0, 1));
    final speed = state.velocity.dot(forward);
    if (_intent.gearRequest != null && speed.abs() < .5) {
      _gear = _intent.gearRequest!;
    }
    final driven = definition.wheels.where((w) => w.driven).length;
    final wheelMass = state.mass / definition.wheels.length;
    final result = <WheelTelemetry>[];
    final impulses = <({Vec3 impulse, Vec3 contact})>[];
    final inputVersion = _inputVersion;
    final epoch = session.epoch;
    for (var i = 0; i < definition.wheels.length; i++) {
      final wheel = definition.wheels[i];
      final origin = state.pose.position + rotation.rotate(wheel.mount);
      final centerAngle = _intent.steer * definition.maxSteerAngle;
      var angle = 0.0;
      if (wheel.steering && centerAngle.abs() > 1e-6) {
        final turnRadius = definition.wheelbase / math.tan(centerAngle.abs());
        angle =
            centerAngle.sign *
            math.atan(
              definition.wheelbase /
                  (turnRadius - centerAngle.sign * wheel.mount.x),
            );
      }
      final hit = body.world.rayCast(
        origin: origin,
        direction: -up,
        maxDistance: wheel.restLength + wheel.travel + wheel.radius,
        filter: QueryFilter(excludeBody: body, excludeSensors: true),
      );
      var length = wheel.restLength + wheel.travel;
      var suspension = 0.0,
          normalLoad = 0.0,
          friction = 0.0,
          longitudinal = 0.0,
          lateral = 0.0;
      var tireForce = Vec3.zero;
      Vec3? contact;
      if (hit != null && hit.normal.dot(up) > .1) {
        contact = origin - up * hit.time;
        length = (hit.time - wheel.radius).clamp(
          0.0,
          wheel.restLength + wheel.travel,
        );
        final relative =
            state.velocity +
            state.angularVelocity.cross(contact - state.pose.position) -
            _vehiclePointVelocity(bodies[hit.body], contact);
        final extension = (wheel.restLength - length).clamp(0.0, wheel.travel);
        suspension =
            (wheel.springRate * extension - wheel.damping * relative.dot(up))
                .clamp(0.0, wheel.maxSuspensionForce);
        normalLoad = suspension * math.max(0.0, up.dot(hit.normal));
        friction =
            surfaceFriction?.call(hit, contact) ?? definition.tireFriction;
        if (!_vehicleIn(friction, 0, 5)) {
          throw StateError('Surface friction must be within 0..5.');
        }
        if (!_live ||
            session.paused ||
            epoch != session.epoch ||
            inputVersion != _inputVersion ||
            _control != null && !_control!.isActive) {
          _loseControl();
          return;
        }
        final steered = rotation.rotate(
          Quat.axisAngle(
            const Vec3(0, 1, 0),
            angle,
          ).rotate(const Vec3(0, 0, 1)),
        );
        final projected = steered - hit.normal * steered.dot(hit.normal);
        if (projected.length > 1e-8) {
          final tireForward = projected.normalized();
          final tireRight = hit.normal.cross(tireForward).normalized();
          longitudinal = relative.dot(tireForward);
          lateral = relative.dot(tireRight);
          final engine =
              wheel.driven && longitudinal * _gear < definition.maxSpeed
              ? definition.engineForce * _intent.throttle * _gear / driven
              : 0.0;
          final braking = math.max(
            _intent.brake,
            _intent.handbrake && !wheel.steering ? 1.0 : 0.0,
          );
          final brake =
              -longitudinal.sign *
              math.min(
                definition.brakeForce * braking / definition.wheels.length,
                wheelMass * longitudinal.abs() / seconds,
              );
          tireForce =
              tireForward * (engine + brake) -
              tireRight * (wheelMass * lateral / seconds);
          final limit = normalLoad * friction;
          if (tireForce.length > limit && tireForce.length > 0) {
            tireForce = tireForce * (limit / tireForce.length);
          }
          impulses.add((
            impulse: up * (suspension * seconds) + tireForce * seconds,
            contact: contact,
          ));
        }
      }
      _rotation[i] =
          (_rotation[i] + longitudinal / wheel.radius * seconds) %
          (2 * math.pi);
      result.add(
        WheelTelemetry(
          id: wheel.id,
          grounded: contact != null,
          suspensionLength: length,
          suspensionForce: suspension,
          normalLoad: normalLoad,
          friction: friction,
          steeringAngle: angle,
          rotation: _rotation[i],
          longitudinalSpeed: longitudinal,
          lateralSpeed: lateral,
          tireForce: tireForce,
          contact: contact,
          contactBody: contact == null ? null : hit!.body,
        ),
      );
    }
    for (final pending in impulses) {
      body.applyImpulse(pending.impulse, at: pending.contact);
    }
    _wheels = List.unmodifiable(result);
    _forceTicks++;
  }

  void _publish() {
    if (!body.isAlive) return;
    final state = body.state;
    _telemetry = VehicleTelemetry(
      tick: session.tick,
      gear: _gear,
      pose: state.pose,
      velocity: state.velocity,
      appliedIntent: _intent,
      wheels: _wheels,
    );
  }
}

Vec3 _vehiclePointVelocity(BodyState? body, Vec3 point) => body == null
    ? Vec3.zero
    : body.velocity + body.angularVelocity.cross(point - body.pose.position);

final class _VehicleBinding {
  final VehicleController controller;
  final Object3D root;
  final List<Object3D> wheels;
  _VehicleBinding(this.controller, this.root, this.wheels);
}

/// Controller forces run before game.physics and never advance the world.
final class GameVehicleSystem extends GameSystem {
  final PhysicsWorld world;
  final PhysicsPlugin physics;
  final int maxVehicles;
  final Map<GameEntityHandle, _VehicleBinding> _bindings = {};
  GameSession? _session;
  GameVehicleSystem({
    required this.world,
    required this.physics,
    this.maxVehicles = 64,
  }) {
    if (!identical(physics.world, world) ||
        !physics.externallyDriven ||
        maxVehicles < 1 ||
        maxVehicles > 1024) {
      throw ArgumentError('Invalid vehicle world or capacity.');
    }
  }
  @override
  String get id => 'game.vehicles';
  @override
  GamePhase get phase => GamePhase.controllers;
  @override
  void start(GameSession session) {
    final simulation = _simulationOwners[world];
    if (_session != null ||
        simulation == null ||
        !identical(simulation.session, session) ||
        !identical(simulation.physics, physics)) {
      throw StateError('Vehicle system needs the simulation physics owner.');
    }
    _session = session;
  }

  GameVehicleRegistration register(
    VehicleController controller, {
    required Object3D presentationRoot,
    required List<Object3D> wheelVisuals,
  }) {
    if (!identical(controller.session, _session) ||
        !identical(controller.body.world, world) ||
        !controller._live ||
        _bindings.containsKey(controller.actor) ||
        _bindings.length >= maxVehicles ||
        wheelVisuals.length != controller.definition.wheels.length ||
        wheelVisuals.toSet().length != wheelVisuals.length ||
        _bindings.values.any(
          (b) => identical(b.controller.body, controller.body),
        )) {
      throw StateError('Vehicle registration is invalid or duplicate.');
    }
    for (final wheel in wheelVisuals) {
      if (!identical(wheel.parent, presentationRoot)) {
        throw ArgumentError('Wheel visuals must be direct chassis children.');
      }
    }
    physics.bind(presentationRoot, controller.body);
    final binding = _VehicleBinding(
      controller,
      presentationRoot,
      List.unmodifiable(wheelVisuals),
    );
    _bindings[controller.actor] = binding;
    return GameVehicleRegistration._(this, binding);
  }

  PhysicsBody? resolveBody(GameEntityHandle actor) {
    final controller = _bindings[actor]?.controller;
    return controller != null && controller._live ? controller.body : null;
  }

  @override
  void fixedUpdate(GameSession session) {
    if (!identical(_session, session)) {
      throw StateError('Vehicle system session differs.');
    }
    final bodies = {for (final body in world.states) body.id: body};
    for (final binding in _bindings.values.toList()) {
      if (!identical(_bindings[binding.controller.actor], binding)) continue;
      if (!binding.controller._live) {
        _remove(binding);
        continue;
      }
      binding.controller._forces(bodies);
    }
  }

  void _present(GameSession session) {
    if (!identical(_session, session)) {
      throw StateError('Vehicle presentation session differs.');
    }
    for (final binding in _bindings.values.toList()) {
      final controller = binding.controller;
      if (!controller._live) {
        _remove(binding);
        continue;
      }
      controller._publish();
      for (var i = 0; i < controller._wheels.length; i++) {
        final wheel = controller._wheels[i];
        binding.wheels[i].position =
            controller.definition.wheels[i].mount -
            const Vec3(0, 1, 0) * wheel.suspensionLength;
        binding.wheels[i].quaternion =
            Quat.axisAngle(const Vec3(0, 1, 0), wheel.steeringAngle) *
            Quat.axisAngle(const Vec3(1, 0, 0), wheel.rotation);
      }
    }
  }

  void _remove(_VehicleBinding binding) {
    if (!identical(_bindings[binding.controller.actor], binding)) return;
    _bindings.remove(binding.controller.actor);
    binding.controller._loseControl();
    physics.unbind(binding.root);
  }

  @override
  void pause(GameSession session) {
    for (final b in _bindings.values.toList()) {
      b.controller._loseControl();
    }
  }

  @override
  void resume(GameSession session) {
    pause(session);
  }

  @override
  void dispose(GameSession session) {
    for (final binding in _bindings.values.toList()) {
      _remove(binding);
    }
    _session = null;
  }
}

final class GameVehiclePresentationSystem extends GameSystem {
  final GameVehicleSystem vehicles;
  GameVehiclePresentationSystem(this.vehicles);
  @override
  String get id => 'game.vehicle-presentation';
  @override
  GamePhase get phase => GamePhase.sensors;
  @override
  Set<String> get dependencies => {'game.vehicles', 'game.physics'};
  @override
  void fixedUpdate(GameSession session) => vehicles._present(session);
}

final class GameVehicleRegistration {
  final GameVehicleSystem _owner;
  final _VehicleBinding _binding;
  bool _disposed = false;
  GameVehicleRegistration._(this._owner, this._binding);
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _owner._remove(_binding);
  }
}
