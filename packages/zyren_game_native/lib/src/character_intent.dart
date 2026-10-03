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
