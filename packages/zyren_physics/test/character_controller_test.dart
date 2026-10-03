import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  late PhysicsWorld world;
  setUp(() => world = PhysicsWorld(fixedStep: .02));
  tearDown(() => world.close());
  PhysicsBody box(
    Vec3 center,
    Vec3 half, {
    BodyKind kind = BodyKind.fixed,
    Quat rotation = Quat.identity,
    bool sensor = false,
  }) {
    final b = world.createBody(
      kind: kind,
      pose: PhysicsPose(position: center, rotation: rotation),
    );
    b.addCollider(BoxShape(half), sensor: sensor);
    return b;
  }

  KinematicCharacterController character({
    Vec3 position = const Vec3(0, .81, 0),
    CharacterControllerSettings? settings,
  }) {
    final b = world.createBody(
      kind: BodyKind.kinematicPosition,
      pose: PhysicsPose(position: position),
    );
    return KinematicCharacterController(
      body: b,
      collider: b.addCollider(const CapsuleShape(halfHeight: .5, radius: .3)),
      settings: settings,
    );
  }

  test('sweeps a thin wall, slides, ignores sensors and stays grounded', () {
    box(const Vec3(0, -.5, 0), const Vec3(20, .5, 20));
    box(const Vec3(2, 1, 0), const Vec3(.02, 1, 10));
    box(const Vec3(.5, 1, 0), const Vec3(.02, 1, 10), sensor: true);
    final c = character();
    final move = c.move(const Vec3(10, -.02, 2));
    world.step();
    expect(c.body.state.pose.position.x, inInclusiveRange(1.65, 1.70));
    expect(c.body.state.pose.position.z, greaterThan(1.8));
    expect(
      move.grounded,
      isTrue,
      reason: '${c.body.state.pose.position} ${move.translation}',
    );
    expect(move.contacts, isNotEmpty);
    expect(c.body.state.pose.position.y, closeTo(.81, .03));
  });
  test('autosteps low stairs and stops at a tall riser', () {
    box(const Vec3(0, -.5, 0), const Vec3(10, .5, 3));
    box(const Vec3(1.4, .1, 0), const Vec3(.6, .1, 2));
    box(const Vec3(3, .7, 0), const Vec3(.2, .7, 2));
    final c = character(settings: CharacterControllerSettings(stepHeight: .25));
    var climbed = false;
    for (var i = 0; i < 100; i++) {
      c.move(const Vec3(.04, -.01, 0));
      world.step();
      climbed |= c.body.state.pose.position.y > .97;
    }
    expect(climbed, isTrue);
    expect(c.body.state.pose.position.x, lessThan(2.51));
  });
  test('steep slope blocks uphill movement and snap follows a small drop', () {
    box(const Vec3(0, -.5, 0), const Vec3(1, .5, 3));
    box(const Vec3(3, -.6, 0), const Vec3(2, .5, 3));
    final c = character();
    for (var i = 0; i < 50; i++) {
      c.move(const Vec3(.04, -.01, 0));
      world.step();
    }
    expect(c.body.state.pose.position.y, closeTo(.71, .03));
    final ramp = box(
      const Vec3(4, .8, 0),
      const Vec3(1.5, .1, 2),
      rotation: Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 3),
    );
    for (var i = 0; i < 100; i++) {
      c.move(const Vec3(.04, -.01, 0));
      world.step();
    }
    expect(c.body.state.pose.position.x, lessThan(ramp.state.pose.position.x));
  });
  test('platform velocity carries the grounded capsule', () {
    final platform = box(
      const Vec3(0, -.25, 0),
      const Vec3(3, .25, 3),
      kind: BodyKind.kinematicVelocity,
    );
    platform.setVelocity(const Vec3(1, 0, 0));
    final c = character();
    for (var i = 0; i < 50; i++) {
      c.move(const Vec3(0, -.01, 0));
      world.step();
    }
    expect(
      c.body.state.pose.position.x,
      closeTo(1, .08),
      reason:
          '${platform.state.pose.position} ${platform.state.velocity} ${c.body.state.pose.position}',
    );
  });
  test('fixed-step callback follows bounded catch-up and pause', () {
    var ticks = 0;
    final plugin = PhysicsPlugin(
      world: world,
      maxCatchUpSteps: 3,
      beforeStep: (dt) {
        expect(dt, .02);
        ticks++;
      },
    );
    plugin.advance(.2);
    expect(ticks, 3);
    expect(plugin.droppedSeconds, greaterThan(.1));
    plugin.paused = true;
    plugin.advance(.2);
    expect(ticks, 3);
  });
  test('stale collider and noncapsule fail before movement', () {
    final c = character();
    c.collider.remove();
    expect(() => c.move(Vec3.zero), throwsStateError);
    final b = world.createBody(kind: BodyKind.kinematicPosition);
    final invalid = KinematicCharacterController(
      body: b,
      collider: b.addCollider(const SphereShape(.3)),
    );
    expect(() => invalid.move(Vec3.zero), throwsA(isA<PhysicsException>()));
  });
}
