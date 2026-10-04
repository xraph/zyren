import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_physics/zyren_physics.dart';

import 'authored_runtime_fixture.dart';

List<Object?> snapshot(BodyState state) => [
  state.id,
  state.kind,
  state.pose.position,
  state.pose.rotation,
  state.velocity,
  state.angularVelocity,
  state.sleeping,
  state.mass,
];
void main() {
  test(
    'persisted default checkpoint consumes radius, saves selection and respawns at authored spawn',
    () async {
      final f = await start();
      final play = f.play, gameplay = f.gameplay;
      final original = f.authored.capture().encode();
      var actor = play.inputActor!;
      try {
        final body = play.resolveBody(actor)!;
        body.teleport(PhysicsPose(position: Vec3(1, 1, 9)));
        advance(play);
        expect(gameplay.selectedCheckpoint(actor), isNull);
        expect(
          gameplay.authored.objectiveComplete(actor, 'checkpoint'),
          isFalse,
        );
        body.teleport(PhysicsPose(position: Vec3(0, 1, 9)));
        advance(play);
        expect(gameplay.selectedCheckpoint(actor)?.id, 'checkpoint');
        expect(gameplay.checkpointActive(actor, 'checkpoint'), isTrue);
        expect(
          gameplay.authored.objectiveComplete(actor, 'checkpoint'),
          isTrue,
        );
        play.pause();
        final save = play.save(), oldActor = actor;
        final corrupt = jsonDecode(save.encode()) as Map;
        (corrupt['state']['game.native-checkpoints']['selections']
            as Map)[actor.id] = [
          'checkpoint',
          'gate',
        ];
        expect(
          () => play.restore(GameSave.decode(jsonEncode(corrupt))),
          throwsFormatException,
        );
        expect(play.save().encode(), save.encode());
        play.restore(save);
        actor = play.inputActor!;
        expect(actor, isNot(oldActor));
        expect(gameplay.selectedCheckpoint(oldActor), isNull);
        expect(gameplay.selectedCheckpoint(actor)?.id, 'checkpoint');
        play.resume();
        final restoredBody = play.resolveBody(actor)!;
        restoredBody.teleport(PhysicsPose(position: Vec3(8, 2, 0)));
        play.actions!.setAxis(deviceId: 'fixture', action: 'move.z', value: 1);
        play.simulation!.session.commands.enqueue(
          GameCommand(actor, play.tick + 1, 'pre-respawn-command'),
          play.simulation!.session.entities,
        );
        expect(gameplay.respawnActor(actor), isTrue);
        final spawn = Vec3.fromVectorMath(
          play.runtimeScene!.objects['spawn']!.worldMatrix
              .toVectorMath()
              .getTranslation(),
        );
        expect(
          restoredBody.state.pose.position.distanceTo(spawn),
          lessThan(1e-6),
        );
        expect(restoredBody.state.velocity, Vec3.zero);
        expect(play.actions!.axis('move.z'), 0);
        expect(play.simulation!.session.commands.length, 0);
        advance(play, 2);
        expect(play.runtimeScene!.objects['gate']!.visible, isTrue);
        expect(
          gameplay.authored.objectiveComplete(actor, 'checkpoint'),
          isTrue,
        );
        expect(f.authored.capture().encode(), original);
      } finally {
        await play.stop();
        play.dispose();
      }
    },
  );

  test(
    'blocked clearance and dead spawn reject respawn without partial mutation',
    () async {
      final f = await start(radius: 2), play = f.play, gameplay = f.gameplay;
      final actor = play.inputActor!;
      try {
        final body = play.resolveBody(actor)!;
        body.teleport(PhysicsPose(position: Vec3(0, 1, 9)));
        advance(play, 2);
        expect(gameplay.selectedCheckpoint(actor)?.id, 'checkpoint');
        body.teleport(PhysicsPose(position: Vec3(6, 2, 0)));
        final spawn = Vec3.fromVectorMath(
          play.runtimeScene!.objects['spawn']!.worldMatrix
              .toVectorMath()
              .getTranslation(),
        );
        final blocker = play.world!.createBody(
          kind: BodyKind.fixed,
          pose: PhysicsPose(position: spawn),
        );
        blocker.addCollider(const BoxShape(Vec3(1, 2, 1)));
        play.actions!.setAxis(deviceId: 'fixture', action: 'move.x', value: .5);
        final before = snapshot(body.state), controlled = play.controlledActor;
        expect(gameplay.respawnActor(actor), isFalse);
        expect(snapshot(body.state), before);
        expect(play.controlledActor, controlled);
        expect(play.actions!.axis('move.x'), closeTo((.5 - .12) / .88, 1e-9));
        blocker.remove();
        final spawnHandle = play.simulation!.session.entities.entities
            .singleWhere((e) => e.handle.id == 'spawn')
            .handle;
        play.simulation!.session.entities.despawn(spawnHandle);
        expect(gameplay.respawnActor(actor), isFalse);
        expect(gameplay.selectedCheckpoint(actor), isNull);
        expect(snapshot(body.state), before);
      } finally {
        await play.stop();
        play.dispose();
      }
    },
  );

  test('checkpoint spawn must be a live authored spawn recipe', () async {
    final counts = PhysicsWorld.nativeCounts;
    await expectLater(start(spawn: 'gate'), throwsStateError);
    expect(PhysicsWorld.nativeCounts, counts);
  });
  test(
    'configured alternate spawn is used instead of the original start',
    () async {
      final f = await start(
        radius: 2,
        spawn: 'alternate-spawn',
        alternateSpawn: true,
      );
      final actor = f.play.inputActor!;
      try {
        final body = f.play.resolveBody(actor)!;
        body.teleport(PhysicsPose(position: const Vec3(0, 1, 9)));
        advance(f.play, 2);
        expect(f.gameplay.selectedSpawn(actor)?.id, 'alternate-spawn');
        expect(f.gameplay.respawnActor(actor), isTrue);
        expect(
          body.state.pose.position.distanceTo(const Vec3(6, 1.5, -3)),
          lessThan(1e-6),
        );
      } finally {
        await f.play.stop();
        f.play.dispose();
      }
    },
  );
}
