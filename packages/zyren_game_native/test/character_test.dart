import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'support/character_fixture.dart';

void main() {
  test(
    'component speed policy normalizes diagonal intent and existing navigation reaches its goal',
    () async {
      final f = await GameCharacterFixture.create(maxSpeed: .4);
      Registration? navigationLease;
      try {
        final definition = GameCharacterDefinition.fromComponent(
          GameComponentRecord(
            'game.character',
            1,
            GameCharacterDefinition(maxSpeed: .4).toJson(),
          ),
        );
        expect(definition.maxSpeed, .4);
        f.controller.apply(const CharacterIntent(moveX: 1, moveZ: 1));
        final origin = f.body.state.pose.position;
        f.step(50);
        final delta = f.body.state.pose.position - origin;
        expect(Vec3(delta.x, 0, delta.z).length, inInclusiveRange(.3, .401));
        f.registration.dispose();
        final floor = Mesh(
          BoxGeometry(width: 6, height: .2, depth: 6),
          UnlitMaterial(),
        )..position = const Vec3(0, -.1, 0);
        final navigation = NavigationWorld(
          NavigationBaker(
            settings: NavigationBakeSettings(
              cellSize: .2,
              radius: .3,
              height: 1.8,
            ),
          ).bake([
            NavigationGeometry.fromMesh(
              floor,
              sourceId: 'floor',
              revision: '1',
            ),
          ]),
        );
        final follower = NavigationFollower(navigation)
          ..setGoal(const Vec3(1, 0, 1));
        final controller = GameCharacterController(
          actor: f.controller.actor,
          session: f.simulation.session,
          motor: f.motor,
          definition: GameCharacterDefinition(maxSpeed: 2),
          navigation: follower,
        );
        navigationLease = f.motors.register(controller, f.actorObject);
        f.step(250);
        final position = f.body.state.pose.position;
        expect(
          Vec3(position.x, 0, position.z).distanceTo(const Vec3(1, 0, 1)),
          lessThan(.04),
          reason:
              'position=$position route=${follower.route?.status} points=${follower.route?.points}',
        );
        expect(follower.replans, greaterThan(0));
      } finally {
        navigationLease?.dispose();
        await f.close();
      }
    },
  );
  test(
    'shared beforeStep drives capsule, imported root motion and IK once per tick',
    () async {
      final before = PhysicsWorld.nativeCounts;
      final f = await GameCharacterFixture.create(maxSpeed: .4);
      try {
        f.controller.apply(
          const CharacterIntent(moveZ: 1, lookYaw: math.pi / 2),
        );
        final start = f.body.state.pose.position;
        final samples = f.ikSamples;
        f.step(50);
        final end = f.body.state.pose.position;
        expect(f.controller.motorTicks, 50);
        expect(end.x - start.x, closeTo(.4, .03));
        expect((end.z - start.z).abs(), lessThan(.01));
        expect(f.controller.grounded, isTrue);
        expect(f.model.nodes[0]!.position, Vec3.zero);
        expect(f.ikSamples, greaterThan(samples));
        expect(f.model.nodes[1]!.quaternion, isNot(Quat.identity));
        expect(f.actorObject.position, end);
        final ticks = f.controller.motorTicks;
        await f.engine.render(
          elapsed: const Duration(seconds: 10),
          width: 8,
          height: 8,
        );
        expect(f.controller.motorTicks, ticks);
        f.controller.apply(const CharacterIntent(jump: true));
        f.step();
        expect(f.controller.grounded, isFalse);
        expect(f.controller.lastIntent.jump, isTrue);
        expect(f.body.state.pose.position.y, greaterThan(end.y));
        f.step(120);
        expect(f.controller.grounded, isTrue);
      } finally {
        await f.close();
      }
      expect(PhysicsWorld.nativeCounts, before);
    },
  );
  test(
    'root motion stops at collision while the imported pose keeps advancing',
    () async {
      final f = await GameCharacterFixture.create();
      try {
        f.box(const Vec3(0, 1, 2), const Vec3(10, 1, .02));
        f.controller.apply(const CharacterIntent(moveZ: 1));
        f.step(200);
        expect(f.body.state.pose.position.z, inInclusiveRange(1.6, 1.72));
        expect(f.model.nodes[0]!.position, Vec3.zero);
        expect(
          f.animation.clocks['walk']!.traversal,
          greaterThan(const Duration(seconds: 3)),
        );
        expect(f.controller.grounded, isTrue);
      } finally {
        await f.close();
      }
    },
  );
  test('motor climbs low stairs and blocks a tall riser', () async {
    final f = await GameCharacterFixture.create();
    try {
      f.box(const Vec3(1.4, .1, 0), const Vec3(.6, .1, 2));
      f.box(const Vec3(3, .7, 0), const Vec3(.2, .7, 2));
      f.controller.apply(const CharacterIntent(moveX: 1));
      var climbed = false;
      for (var i = 0; i < 200; i++) {
        f.step();
        climbed |= f.body.state.pose.position.y > .97;
      }
      expect(climbed, isTrue);
      expect(f.body.state.pose.position.x, lessThan(2.51));
    } finally {
      await f.close();
    }
  });
  test(
    'motor blocks a steep slope and rides a moving native platform',
    () async {
      final slope = await GameCharacterFixture.create();
      try {
        slope.box(
          const Vec3(4, .8, 0),
          const Vec3(1.5, .1, 2),
          rotation: Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 3),
        );
        slope.controller.apply(const CharacterIntent(moveX: 1));
        slope.step(300);
        expect(slope.body.state.pose.position.x, lessThan(4));
      } finally {
        await slope.close();
      }
      final f = await GameCharacterFixture.create(floor: false);
      try {
        final platform = f.box(
          const Vec3(0, -.25, 0),
          const Vec3(3, .25, 3),
          kind: BodyKind.kinematicVelocity,
        );
        f.step(15);
        expect(f.controller.grounded, isTrue);
        platform.setVelocity(const Vec3(1, 0, 0));
        f.step(50);
        expect(f.controller.grounded, isTrue);
        expect(f.body.state.pose.position.x, closeTo(1, .08));
      } finally {
        await f.close();
      }
    },
  );
  test(
    'possession switches and epochs reject stale producers and entity generations',
    () async {
      final f = await GameCharacterFixture.create();
      try {
        final first = f.controller.acquireControl();
        f.controller.apply(const CharacterIntent(moveX: 1), lease: first);
        final second = f.controller.acquireControl();
        expect(first.isActive, isFalse);
        expect(
          () =>
              f.controller.apply(const CharacterIntent(moveX: 1), lease: first),
          throwsStateError,
        );
        expect(
          () => f.controller.apply(const CharacterIntent(moveX: 1)),
          throwsStateError,
        );
        f.controller.apply(const CharacterIntent(), lease: second);
        f.step(5);
        expect(f.body.state.pose.position.x, closeTo(0, .001));
        f.controller.apply(const CharacterIntent(moveX: 1), lease: second);
        f.simulation.session.invalidatePending();
        expect(second.isActive, isFalse);
        f.step(5);
        expect(f.body.state.pose.position.x, closeTo(0, .001));
        f.simulation.session.pause();
        expect(second.isActive, isFalse);
        f.simulation.session.resume();
        final third = f.controller.acquireControl();
        final actor = f.controller.actor;
        expect(
          () => f.controller.applyGameIntent(
            GameIntent(
              actor: actor,
              tick: f.simulation.session.tick + 1,
              epoch: f.simulation.session.epoch - 1,
              actions: {'move.x': 1},
            ),
            lease: third,
          ),
          throwsStateError,
        );
        f.simulation.session.entities.despawn(actor);
        final replacement = f.simulation.session.entities.spawn(actor.id);
        expect(replacement.generation, greaterThan(actor.generation));
        expect(
          () =>
              f.controller.apply(const CharacterIntent(moveX: 1), lease: third),
          throwsStateError,
        );
        f.step();
        expect(third.isActive, isFalse);
        expect(f.motors.resolveBody(actor), isNull);
      } finally {
        await f.close();
      }
    },
  );
  test(
    'invalid intents and duplicate motor clocks reject before moving',
    () async {
      final f = await GameCharacterFixture.create();
      try {
        expect(
          () => f.controller.apply(const CharacterIntent(moveX: 2)),
          throwsArgumentError,
        );
        expect(
          () => f.controller.apply(const CharacterIntent(lookYaw: double.nan)),
          throwsArgumentError,
        );
        expect(
          () => f.motors.register(f.controller, Group()),
          throwsStateError,
        );
      } finally {
        await f.close();
      }
    },
  );
}
