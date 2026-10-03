part of '../zyren_game_native.dart';

final _driverOwners = Expando<GamePhysicsDriver>('game physics driver');

/// Uses the PhysicsPlugin accumulator and its beforeStep motor hook.
final class GamePhysicsDriver extends GameSystem {
  final PhysicsPlugin physics;
  GameSession? _session;
  GamePhysicsDriver(this.physics) {
    if (!physics.externallyDriven) {
      throw ArgumentError('Game physics must be externally driven.');
    }
  }
  @override
  String get id => 'game.physics';
  @override
  GamePhase get phase => GamePhase.physics;
  @override
  void start(GameSession session) {
    if (physics.world.isClosed) throw StateError('Physics world is closed.');
    if ((physics.world.fixedStep - session.stepSeconds).abs() > 1e-12) {
      throw ArgumentError('Physics and game fixed rates must match.');
    }
    if (_session != null || _driverOwners[physics.world] != null) {
      throw StateError('Physics world already has a game driver.');
    }
    _driverOwners[physics.world] = this;
    _session = session;
    physics.paused = false;
  }

  @override
  void fixedUpdate(GameSession session) {
    if (!identical(_session, session) ||
        !identical(_driverOwners[physics.world], this)) {
      throw StateError('Game does not own this physics driver.');
    }
    if (physics.paused) {
      throw StateError('Physics was paused outside its game session.');
    }
    physics.advance(session.stepSeconds);
  }

  @override
  void pause(GameSession session) {
    physics.paused = true;
  }

  @override
  void resume(GameSession session) {
    physics.paused = false;
  }

  @override
  void dispose(GameSession session) {
    if (identical(_driverOwners[physics.world], this)) {
      _driverOwners[physics.world] = null;
      physics.paused = true;
    }
    _session = null;
  }
}
