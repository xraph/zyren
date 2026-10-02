import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test('query refresh preserves sensor entry and removal retains IDs', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final sensor = world.createBody(kind: BodyKind.fixed);
      final sensorCollider = sensor.addCollider(
        const SphereShape(2),
        sensor: true,
      );
      final body = world.createBody();
      final collider = body.addCollider(const SphereShape(.5));
      world.rayCast(
        origin: const Vec3(0, 5, 0),
        direction: const Vec3(0, -1, 0),
      );
      final entered = world.step().events.where((e) => e.sensor && e.started);
      expect(entered, hasLength(1));
      expect(
        {entered.single.collider1, entered.single.collider2},
        {sensorCollider.id, collider.id},
      );
      body.remove();
      world.overlap(shape: const SphereShape(3), pose: PhysicsPose());
      final exited = world.step().events.where((e) => e.sensor && !e.started);
      expect(exited, hasLength(1));
      expect(
        {exited.single.collider1, exited.single.collider2},
        {sensorCollider.id, collider.id},
      );
    } finally {
      world.close();
    }
  });

  test('groups filter collisions and queries after material updates', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final a = world.createBody(kind: BodyKind.fixed);
      final ac = a.addCollider(
        const SphereShape(2),
        sensor: true,
        membership: 1,
        filter: 1,
      );
      final b = world.createBody();
      final bc = b.addCollider(const SphereShape(.5), membership: 2, filter: 2);
      expect(world.step().events.where((e) => e.kind == 'collision'), isEmpty);
      expect(
        world.overlap(
          shape: const SphereShape(3),
          pose: PhysicsPose(),
          filter: const QueryFilter(membership: 1, filter: 1),
        ),
        [ac.id],
      );
      ac.configure(sensor: true, membership: 1, filter: 2);
      bc.configure(membership: 2, filter: 1, restitution: .8, friction: .2);
      expect(world.step().events.any((e) => e.sensor && e.started), isTrue);
      expect(
        world.rayCast(
          origin: const Vec3(0, 5, 0),
          direction: const Vec3(0, -1, 0),
          filter: QueryFilter(excludeBody: b, excludeSensors: true),
        ),
        isNull,
      );
      expect(
        () => bc.configure(restitution: 2),
        throwsA(isA<PhysicsException>()),
      );
      expect(world.step().bodies, hasLength(2));
    } finally {
      world.close();
    }
  });

  test('snapshots retain pending query events and drains consume once', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      world
          .createBody(kind: BodyKind.fixed)
          .addCollider(const SphereShape(2), sensor: true);
      world.createBody().addCollider(const SphereShape(.5));
      world.overlap(shape: const SphereShape(3), pose: PhysicsPose());
      final snapshot = world.snapshot();
      expect(world.drainEvents().where((e) => e.started), hasLength(1));
      expect(world.drainEvents(), isEmpty);
      world.restore(snapshot);
      expect(world.step().events.where((e) => e.started), hasLength(1));
      expect(world.step().events.where((e) => e.started), isEmpty);
    } finally {
      world.close();
    }
  });

  test('CCD prevents a fast sphere crossing a thin obstacle', () {
    double run(bool ccd) {
      final world = PhysicsWorld(gravity: Vec3.zero);
      try {
        world
            .createBody(kind: BodyKind.fixed)
            .addCollider(const BoxShape(Vec3(3, .02, 3)));
        final body = world.createBody(
          pose: PhysicsPose(position: const Vec3(0, 2, 0)),
          velocity: const Vec3(0, -1000, 0),
          ccd: ccd,
        );
        body.addCollider(const SphereShape(.1));
        world.step();
        expect(body.state.ccdEnabled, ccd);
        return body.state.pose.position.y;
      } finally {
        world.close();
      }
    }

    expect(run(true), greaterThan(.08));
  });

  test('hinge and slider motors respect limits and reverse at runtime', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final anchor = world.createBody(kind: BodyKind.fixed);
      final rotor = world.createBody();
      rotor.addCollider(const BoxShape(Vec3(.5, .2, .2)));
      world.createJoint(
        body1: anchor,
        body2: rotor,
        kind: JointKind.hinge,
        axis: const Vec3(0, 0, 1),
        limits: [-.35, .35],
        motorVelocity: 2,
        maxForce: 100,
      );
      final carriage = world.createBody();
      carriage.addCollider(const SphereShape(.2), sensor: true);
      final slider = world.createJoint(
        body1: anchor,
        body2: carriage,
        kind: JointKind.slider,
        axis: const Vec3(1, 0, 0),
        limits: [-.5, .5],
        motorVelocity: 1,
        maxForce: 100,
      );
      for (var i = 0; i < 180; i++) {
        world.step();
      }
      final q = rotor.state.pose.rotation;
      expect(2 * math.atan2(q.z, q.w), closeTo(.35, .02));
      expect(carriage.state.pose.position.x, closeTo(.5, .02));
      slider.setMotor(
        axis: MotorAxis.linearX,
        velocity: -1,
        damping: 1,
        maxForce: 100,
      );
      for (var i = 0; i < 180; i++) {
        world.step();
      }
      expect(carriage.state.pose.position.x, closeTo(-.5, .02));
      expect(
        () => slider.setMotor(axis: MotorAxis.angularY),
        throwsA(isA<PhysicsException>()),
      );
      expect(world.debugLines().any((line) => line.kind == 'joint'), isTrue);
    } finally {
      world.close();
    }
  });

  test('distance, spring, spherical and fixed constraints hold anchors', () {
    for (final kind in [
      JointKind.distance,
      JointKind.spring,
      JointKind.spherical,
      JointKind.fixed,
    ]) {
      final world = PhysicsWorld(gravity: Vec3.zero);
      try {
        final anchor = world.createBody(kind: BodyKind.fixed);
        final body = world.createBody(
          pose: PhysicsPose(
            position: Vec3(
              kind == JointKind.spherical || kind == JointKind.fixed ? 1 : 3,
              0,
              0,
            ),
          ),
          mass: 1,
          inertia: Vec3.one,
        );
        world.createJoint(
          body1: anchor,
          body2: body,
          kind: kind,
          length: 1,
          stiffness: 50,
          damping: 10,
          anchor2: kind == JointKind.spherical
              ? const Vec3(-1, 0, 0)
              : Vec3.zero,
          frame1: PhysicsPose(position: const Vec3(1, 0, 0)),
        );
        for (var i = 0; i < 240; i++) {
          world.step();
        }
        expect(
          body.state.pose.position.length,
          closeTo(1, .04),
          reason: kind.name,
        );
        body.applyImpulse(const Vec3(-.5, 0, 0));
        for (var i = 0; i < 180; i++) {
          world.step();
        }
        if (kind == JointKind.distance) {
          expect(
            body.state.pose.position.length,
            lessThan(.95),
            reason: 'Maximum-distance constraints permit rope slack.',
          );
        } else {
          expect(
            body.state.pose.position.length,
            closeTo(1, .06),
            reason: '${kind.name} must also resist compression',
          );
        }
      } finally {
        world.close();
      }
    }
  });

  test('offsets, triangle queries and replay preserve real state', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final fixed = world.createBody(
        pose: PhysicsPose(position: const Vec3(5, 0, 0)),
        kind: BodyKind.fixed,
      );
      final collider = fixed.addCollider(
        const SphereShape(.5),
        offset: PhysicsPose(position: const Vec3(1, 0, 0)),
      );
      expect(
        world
            .rayCast(
              origin: const Vec3(6, 3, 0),
              direction: const Vec3(0, -1, 0),
            )!
            .collider,
        collider.id,
      );
      fixed.addCollider(
        TriangleMeshShape(
          [const Vec3(0, 0, 0), const Vec3(1, 0, 0), const Vec3(0, 0, 1)],
          [
            [0, 1, 2],
          ],
        ),
      );
      final body = world.createBody(velocity: const Vec3(1, 2, 0));
      body.addCollider(const SphereShape(.1));
      world.step();
      final snapshot = world.snapshot();
      for (var i = 0; i < 60; i++) {
        world.step();
      }
      final expected = body.state;
      world.restore(snapshot);
      final replay = world.body(body.id);
      for (var i = 0; i < 60; i++) {
        world.step();
      }
      expect(replay.state.pose.position, expected.pose.position);
      expect(replay.state.velocity, expected.velocity);
      expect(
        () => world.restore(PhysicsSnapshot.decode('{"version":99}')),
        throwsA(isA<PhysicsException>()),
      );
      expect(replay.isAlive, isTrue);
      world.step();
    } finally {
      world.close();
    }
  });
}
