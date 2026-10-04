part of '../zyren_game_native.dart';

/// A possession lease is specific to this controller, actor generation and epoch.
final class GameCharacterControlLease {
  final GameCharacterController _owner;
  final GameEntityHandle actor;
  final int generation, epoch;
  bool _active = true;
  GameCharacterControlLease._(
    this._owner,
    this.actor,
    this.generation,
    this.epoch,
  );
  bool get isActive =>
      _active &&
      identical(_owner._control, this) &&
      _owner._live &&
      _owner.session.epoch == epoch;
  void dispose() {
    if (!_active) return;
    _active = false;
    if (identical(_owner._control, this)) _owner._resetIntent();
  }
}

/// Intent drives the existing motor, then native physics writes the outer pose.
final class GameCharacterController {
  final GameEntityHandle actor;
  final GameSession session;
  final CharacterMotor motor;
  final GameCharacterDefinition definition;
  final NavigationFollower? navigation;
  final Vec3 navigationOriginOffset;
  CharacterIntent _intent = const CharacterIntent(),
      _lastIntent = const CharacterIntent();
  GameCharacterControlLease? _control;
  ({GameIntent intent, GameCharacterControlLease lease})? _futureIntent;
  int _controlGeneration = 0, _motorTicks = 0, _lastTick = -1, _intentEpoch = 0;
  int _movementEpoch = -1;
  bool _jumpPending = false, _interactPending = false;
  final void Function(GameEntityHandle actor)? onInteract;
  GameCharacterController({
    required this.actor,
    required this.session,
    required this.motor,
    required this.definition,
    this.navigation,
    this.onInteract,
    this.navigationOriginOffset = const Vec3(0, -.81, 0),
  }) {
    _intentEpoch = session.epoch;
    if (!session.entities.isAlive(actor) ||
        definition.jumpSpeed > motor.terminalSpeed ||
        !motor.character.states.any((s) => s.id == definition.idleState) ||
        !motor.character.states.any((s) => s.id == definition.movingState) ||
        !navigationOriginOffset.isFinite ||
        navigationOriginOffset.length > 10) {
      throw ArgumentError(
        'Character needs a live actor and valid motor states.',
      );
    }
  }
  bool get _live =>
      !session.isClosed &&
      session.fault == null &&
      session.entities.isAlive(actor) &&
      motor.controller.body.isAlive;
  bool get grounded => motor.grounded;
  CharacterIntent get lastIntent => _lastIntent;
  int get motorTicks => _motorTicks;

  /// Contacts from this tick's completed motor advance, never a prior epoch.
  List<CharacterContact> get currentContacts =>
      _live &&
          !session.paused &&
          _lastTick == session.tick &&
          _movementEpoch == session.epoch
      ? motor.lastMovement?.contacts ?? const []
      : const [];
  GameCharacterControlLease acquireControl() {
    _requireLive();
    _resetIntent();
    return _control = GameCharacterControlLease._(
      this,
      actor,
      ++_controlGeneration,
      session.epoch,
    );
  }

  void _requireLive() {
    if (!_live || session.paused) throw StateError('Character is unavailable.');
  }

  void apply(CharacterIntent intent, {GameCharacterControlLease? lease}) {
    _requireLive();
    intent.validate();
    _checkProducer(lease);
    _futureIntent = null;
    if (intent.moveX != 0 || intent.moveZ != 0) navigation?.setGoal(null);
    _intent = intent;
    _intentEpoch = session.epoch;
    _jumpPending |= intent.jump;
    _interactPending |= intent.interact;
  }

  void _checkProducer(GameCharacterControlLease? lease) {
    if (lease != null && (!identical(_control, lease) || !lease.isActive) ||
        lease == null && _control != null) {
      throw StateError('Character intent producer no longer owns control.');
    }
  }

  void applyGameIntent(
    GameIntent intent, {
    required GameCharacterControlLease lease,
  }) {
    _requireLive();
    if (intent.actor != actor ||
        intent.epoch != session.epoch ||
        intent.tick < session.tick ||
        intent.tick > session.tick + 1) {
      throw StateError('Character intent envelope is stale.');
    }
    final characterIntent = CharacterIntent.fromGameIntent(intent);
    characterIntent.validate();
    _checkProducer(lease);
    if (intent.tick > session.tick) {
      _futureIntent = (intent: intent, lease: lease);
      return;
    }
    apply(characterIntent, lease: lease);
  }

  void _resetIntent() {
    _control?._active = false;
    _control = null;
    _intent = const CharacterIntent();
    _lastIntent = const CharacterIntent();
    _jumpPending = false;
    _interactPending = false;
    _intentEpoch = session.epoch;
    _futureIntent = null;
    navigation?.setGoal(null);
  }

  void _advance(double seconds) {
    _requireLive();
    if (_intentEpoch != session.epoch ||
        _control != null && !_control!.isActive) {
      _resetIntent();
    }
    final future = _futureIntent;
    if (future != null && future.intent.tick <= session.tick) {
      _futureIntent = null;
      if (future.intent.tick == session.tick &&
          future.intent.epoch == session.epoch &&
          future.lease.isActive) {
        apply(
          CharacterIntent.fromGameIntent(future.intent),
          lease: future.lease,
        );
      }
    }
    if (_lastTick == session.tick) {
      throw StateError('Motor already advanced this tick.');
    }
    if (!motor.character.isAttached || motor.character.isPaused) {
      throw StateError(
        'Attach and resume character animation before simulation.',
      );
    }
    _lastTick = session.tick;
    _lastIntent = _intent;
    final axes = Vec3(_intent.moveX, 0, _intent.moveZ);
    final strength = math.min(1.0, axes.length);
    final moving = strength > 0 || navigation?.goal != null;
    final state = moving ? definition.movingState : definition.idleState;
    if (motor.character.currentState != state) {
      motor.character.transitionTo(state);
    }
    final jumping = _jumpPending && motor.grounded && definition.jumpSpeed > 0;
    final adhesion = motor.grounded && !jumping && !moving
        ? Vec3(
            0,
            -math.max(
                  0.0,
                  definition.groundStickSpeed + motor.gravity * seconds,
                ) *
                seconds,
            0,
          )
        : Vec3.zero;
    if (jumping) {
      motor.jump(definition.jumpSpeed);
    }
    _jumpPending = false;
    motor.advance(
      Duration(microseconds: (seconds * 1000000).round()),
      steer: (distance) {
        final capped = math.min(distance, definition.maxSpeed * seconds);
        if (navigation?.goal != null) {
          final position = motor.controller.body.state.pose.position;
          var feet = position + navigationOriginOffset;
          final ground = motor.controller.body.world.rayCast(
            origin: Vec3(feet.x, position.y, feet.z),
            direction: const Vec3(0, -1, 0),
            maxDistance: math.min(20.0, navigationOriginOffset.length + 1),
            filter: QueryFilter(
              excludeBody: motor.controller.body,
              excludeSensors: true,
            ),
          );
          if (ground != null &&
              ground.normal.y >= math.cos(motor.controller.settings.maxSlope)) {
            feet = Vec3(feet.x, position.y - ground.time, feet.z);
          }
          final travel = navigation!.intent(feet, capped);
          return Vec3(travel.x, 0, travel.z) + adhesion;
        }
        if (strength == 0) return adhesion;
        return Quat.axisAngle(
                  const Vec3(0, 1, 0),
                  _intent.lookYaw,
                ).rotate(axes.normalized()) *
                (capped * strength) +
            adhesion;
      },
    );
    _motorTicks++;
    _movementEpoch = session.epoch;
    if (_interactPending) {
      _interactPending = false;
      onInteract?.call(actor);
    }
  }
}

/// Install [advance] as PhysicsPlugin.beforeStep before creating the simulation.
final class GameCharacterMotorRegistry {
  final PhysicsWorld world;
  final int maxCharacters;
  final Map<
    GameEntityHandle,
    ({
      GameCharacterController controller,
      Object3D object,
      Registration registration,
    })
  >
  _characters = {};
  GameSimulation? _simulation;
  GameEventSubscription? _state;
  GameCharacterMotorRegistry(this.world, {this.maxCharacters = 128}) {
    if (maxCharacters < 1 || maxCharacters > 1024) {
      throw ArgumentError('Invalid character registry bound.');
    }
  }
  Registration connect(GameSimulation simulation) {
    if (_simulation != null ||
        simulation.session.isClosed ||
        !identical(world, simulation.world) ||
        simulation.physics.beforeStep != advance) {
      throw StateError(
        'Connect one simulation using this registry beforeStep.',
      );
    }
    _simulation = simulation;
    _state = simulation.session.listenState(() {
      if (simulation.session.paused ||
          simulation.session.isClosed ||
          simulation.session.fault != null) {
        for (final entry in _characters.values.toList()) {
          entry.controller._resetIntent();
        }
      }
    });
    return Registration(() {
      if (!identical(_simulation, simulation)) return;
      for (final entry in _characters.values.toList()) {
        entry.registration.dispose();
      }
      _state?.cancel();
      _state = null;
      _simulation = null;
    });
  }

  Registration register(
    GameCharacterController controller,
    Object3D presentationRoot,
  ) {
    final simulation = _simulation;
    if (simulation == null ||
        !identical(controller.session, simulation.session) ||
        !identical(controller.motor.controller.body.world, world) ||
        !controller._live ||
        _characters.containsKey(controller.actor) ||
        _characters.length >= maxCharacters ||
        _characters.values.any(
          (c) => identical(
            c.controller.motor.character.timeline,
            controller.motor.character.timeline,
          ),
        )) {
      throw StateError(
        'Character registration needs a unique live actor and animation clock.',
      );
    }
    if (!controller.motor.character.isAttached) {
      throw StateError('Character animation is not attached.');
    }
    for (final state in controller.motor.character.states) {
      for (final track in state.clip.tracks) {
        var beneath = false;
        for (
          Object3D? node = track.target.parent;
          node != null;
          node = node.parent
        ) {
          if (identical(node, presentationRoot)) {
            beneath = true;
            break;
          }
        }
        if (!beneath) {
          throw StateError(
            'Animation must target children beneath the physics root.',
          );
        }
      }
    }
    simulation.physics.bind(presentationRoot, controller.motor.controller.body);
    late Registration registration;
    registration = Registration(() {
      final entry = _characters[controller.actor];
      if (entry == null || !identical(entry.registration, registration)) return;
      _characters.remove(controller.actor);
      controller._resetIntent();
      simulation.physics.unbind(presentationRoot);
    });
    _characters[controller.actor] = (
      controller: controller,
      object: presentationRoot,
      registration: registration,
    );
    return registration;
  }

  PhysicsBody? resolveBody(GameEntityHandle actor) {
    final controller = _characters[actor]?.controller;
    return controller != null && controller._live
        ? controller.motor.controller.body
        : null;
  }

  void advance(double seconds) {
    final simulation = _simulation;
    if (simulation == null ||
        simulation.session.isClosed ||
        simulation.session.paused ||
        !seconds.isFinite ||
        (seconds - simulation.session.stepSeconds).abs() > 1e-12) {
      throw StateError('Motor registry requires its active game fixed step.');
    }
    for (final entry in _characters.values.toList()) {
      if (!identical(
        _characters[entry.controller.actor]?.registration,
        entry.registration,
      )) {
        continue;
      }
      if (!entry.controller._live) {
        entry.registration.dispose();
        continue;
      }
      entry.controller._advance(seconds);
      if (!entry.controller._live) entry.registration.dispose();
    }
  }
}
