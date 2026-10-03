part of '../../runtime.dart';

/// One native NPC producer, tied to its entity generation and session epoch.
final class GameRuntimeActorControl {
  final GameLevelRuntime _owner;
  final GameEntityHandle actor;
  final int epoch, generation;
  final GameCharacterControlLease? _character;
  final VehicleControlLease? _vehicle;
  bool _active = true;
  GameRuntimeActorControl._(
    this._owner,
    this.actor,
    this.epoch,
    this.generation,
    this._character,
    this._vehicle,
  );
  bool get isActive =>
      _active &&
      !_owner.isClosed &&
      _owner.error == null &&
      !_owner.isPaused &&
      _owner.simulation?.session.epoch == epoch &&
      identical(_owner._actorControls[actor], this) &&
      _owner._controlled != actor &&
      _owner._inputActor != actor &&
      _owner._active[actor.id] != false &&
      _owner.resolveBody(actor)?.isAlive == true &&
      (_character == null || _character.isActive) &&
      (_vehicle == null || _vehicle.isActive);
  void _requireActive() {
    if (!isActive) {
      throw StateError('Native actor control is stale or unavailable.');
    }
  }

  void applyCharacter(CharacterIntent intent) {
    _requireActive();
    intent.validate();
    if (_vehicle != null) {
      throw StateError('Vehicle control requires VehicleIntent.');
    }
    if (_character != null) {
      _owner._characters[actor]!.apply(intent, lease: _character);
    } else {
      _owner._primitiveIntents[actor] = intent;
    }
  }

  void applyVehicle(VehicleIntent intent) {
    _requireActive();
    if (_vehicle == null) {
      throw StateError('Character control requires CharacterIntent.');
    }
    _owner._vehicleControllers[actor]!.apply(intent, lease: _vehicle);
  }

  void dispose() {
    if (!_active) return;
    _active = false;
    _character?.dispose();
    _vehicle?.dispose();
    if (identical(_owner._actorControls[actor], this)) {
      _owner._actorControls.remove(actor);
      _owner._primitiveIntents.remove(actor);
    }
  }
}

GameRuntimeActorControl? _acquireActorControl(
  GameLevelRuntime owner,
  GameEntityHandle actor,
) {
  final session = owner.simulation?.session;
  if (owner.isClosed ||
      owner.error != null ||
      owner._restoringCheckpoint ||
      !owner._setupReady ||
      session == null ||
      session.paused ||
      !session.entities.isAlive(actor) ||
      owner._controlled == actor ||
      owner._inputActor == actor ||
      owner._active[actor.id] == false ||
      owner.resolveBody(actor)?.isAlive != true) {
    return null;
  }
  final previous = owner._actorControls[actor];
  if (previous?.isActive == true) return null;
  previous?.dispose();
  final character = owner._characters[actor],
      vehicle = owner._vehicleControllers[actor];
  if (character == null &&
      vehicle == null &&
      !owner._primitiveCharacters.containsKey(actor)) {
    return null;
  }
  if (owner._nextActorControl >= 9000000000000000) {
    throw StateError('Native control generation exhausted.');
  }
  final control = GameRuntimeActorControl._(
    owner,
    actor,
    session.epoch,
    ++owner._nextActorControl,
    character?.acquireControl(),
    vehicle?.acquireControl(actor),
  );
  owner._actorControls[actor] = control;
  return control;
}

final class _PrimitiveControllers extends GameSystem {
  final GameLevelRuntime owner;
  _PrimitiveControllers(this.owner);
  @override
  String get id => 'game.primitive-controllers';
  @override
  GamePhase get phase => GamePhase.controllers;
  @override
  Set<String> get dependencies => {'game.play-setup'};
  @override
  void fixedUpdate(GameSession session) {
    for (final entry in owner._primitiveCharacters.entries) {
      if (!session.entities.isAlive(entry.key) ||
          owner._active[entry.key.id] == false) {
        continue;
      }
      final user =
          entry.key == owner._controlled &&
          owner._inputActor != null &&
          owner._possession?.seatOf(owner._inputActor!) == entry.key.id;
      final external = owner._actorControls[entry.key];
      final intent = user || external?.isActive == true
          ? owner._primitiveIntents[entry.key] ?? const CharacterIntent()
          : const CharacterIntent();
      entry.value.advance(intent, session.stepSeconds);
      owner._primitiveIntents[entry.key] = CharacterIntent(
        moveX: intent.moveX,
        moveZ: intent.moveZ,
        lookYaw: intent.lookYaw,
        lookPitch: intent.lookPitch,
      );
    }
  }
}
