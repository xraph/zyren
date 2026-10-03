part of '../zyren_game_native.dart';

/// Movement axes are normalized; look angles are absolute camera radians.
final class CharacterIntent {
  final double moveX, moveZ, lookYaw, lookPitch;
  final bool jump, interact;
  const CharacterIntent({
    this.moveX = 0,
    this.moveZ = 0,
    this.lookYaw = 0,
    this.lookPitch = 0,
    this.jump = false,
    this.interact = false,
  });
  factory CharacterIntent.fromGameIntent(GameIntent intent) => CharacterIntent(
    moveX: intent.actions['move.x'] ?? 0,
    moveZ: intent.actions['move.z'] ?? 0,
    lookYaw: (intent.actions['look.yaw'] ?? 0) * math.pi,
    lookPitch: (intent.actions['look.pitch'] ?? 0) * math.pi / 2,
    jump: (intent.actions['jump'] ?? 0) > 0,
    interact: (intent.actions['interact'] ?? 0) > 0,
  );
  void validate() {
    if (![moveX, moveZ, lookYaw, lookPitch].every((v) => v.isFinite) ||
        moveX.abs() > 1 ||
        moveZ.abs() > 1 ||
        lookPitch.abs() > math.pi / 2) {
      throw ArgumentError('Invalid character intent.');
    }
  }
}

/// Component policy bounds extracted root motion and jumping.
final class GameCharacterDefinition {
  final double maxSpeed, jumpSpeed, groundStickSpeed;
  final String idleState, movingState;
  GameCharacterDefinition({
    this.maxSpeed = 4,
    this.jumpSpeed = 5,
    this.groundStickSpeed = .5,
    this.idleState = 'idle',
    this.movingState = 'walk',
  }) {
    if (!maxSpeed.isFinite ||
        maxSpeed < 0 ||
        maxSpeed > 100 ||
        !jumpSpeed.isFinite ||
        jumpSpeed < 0 ||
        jumpSpeed > 50 ||
        !groundStickSpeed.isFinite ||
        groundStickSpeed < 0 ||
        groundStickSpeed > 5 ||
        idleState.isEmpty ||
        movingState.isEmpty ||
        idleState.length > 128 ||
        movingState.length > 128 ||
        idleState == movingState) {
      throw ArgumentError('Invalid character definition.');
    }
  }
  Map<String, Object?> toJson() => {
    'maxSpeed': maxSpeed,
    'jumpSpeed': jumpSpeed,
    'groundStickSpeed': groundStickSpeed,
    'idleState': idleState,
    'movingState': movingState,
  };
  factory GameCharacterDefinition.fromComponent(GameComponentRecord record) {
    if (record.type != 'game.character' || record.version != 1) {
      throw const FormatException('Unsupported character component.');
    }
    return GameCharacterDefinition.fromJson(record.data);
  }
  factory GameCharacterDefinition.fromJson(Map<String, Object?> value) =>
      GameCharacterDefinition(
        maxSpeed: (value['maxSpeed'] as num).toDouble(),
        jumpSpeed: (value['jumpSpeed'] as num).toDouble(),
        groundStickSpeed: (value['groundStickSpeed'] as num?)?.toDouble() ?? .5,
        idleState: value['idleState'] as String,
        movingState: value['movingState'] as String,
      );
}
