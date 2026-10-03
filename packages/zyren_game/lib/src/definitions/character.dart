part of '../../zyren_game.dart';

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
