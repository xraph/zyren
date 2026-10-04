import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';

/// Reference-game movement and sound use the same authoritative game clock.
final class GameReferenceWorld extends GameSystem {
  final GameLevelRuntime runtime;
  GameReferenceWorld(this.runtime);
  @override
  String get id => 'game-lab.world';
  @override
  GamePhase get phase => GamePhase.commands;
  @override
  void fixedUpdate(GameSession session) {
    final hazard = session.entities.entities
        .where((e) => e.handle.id == 'moving-hazard')
        .firstOrNull
        ?.handle;
    if (hazard != null) {
      runtime
          .resolveBody(hazard)
          ?.setTarget(
            PhysicsPose(
              position: Vec3(
                -5 + math.sin(session.tick * session.stepSeconds) * 2,
                .6,
                9,
              ),
            ),
          );
    }
    final player = runtime.inputActor;
    final body = player == null ? null : runtime.resolveBody(player);
    if (body == null ||
        session.tick % 10 != 0 ||
        body.state.velocity.length < .2) {
      return;
    }
    GameSoundPublisher(session).emit(
      GameSoundEvent(
        id: 'footstep-${session.tick}',
        category: 'footstep',
        tick: session.tick,
        sourceEntityId: player!.id,
        position: body.state.pose.position,
        loudness: .7,
        range: 12,
      ),
    );
  }
}
