import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test('native collision, contact, sensors, queries and cleanup', () {
    final baseline = PhysicsWorld.nativeCounts;
    final world = PhysicsWorld();
    try {
      final floor = world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(0, -.5, 0)),
      );
      final floorCollider = floor.addCollider(const BoxShape(Vec3(5, .5, 5)));
      final ball = world.createBody(
        pose: PhysicsPose(position: const Vec3(0, 3, 0)),
        ccd: true,
      );
      ball.addCollider(const SphereShape(.5), restitution: .1);
      final sensor = world.createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(0, 1.5, 0)),
      );
      sensor.addCollider(const BoxShape(Vec3(2, .2, 2)), sensor: true);
      final events = <PhysicsEvent>[];
      for (var i = 0; i < 180; i++) {
        events.addAll(world.step().events);
      }
      expect(ball.state.pose.position.y, closeTo(.5, .04));
      expect(events.any((e) => e.sensor && e.started), isTrue);
      expect(events.any((e) => e.sensor && !e.started), isTrue);
      expect(events.any((e) => e.kind == 'contact' && e.magnitude > 0), isTrue);
      expect(
        world
            .rayCast(
              origin: const Vec3(3, 5, 0),
              direction: const Vec3(0, -1, 0),
              filter: const QueryFilter(excludeSensors: true),
            )!
            .collider,
        floorCollider.id,
      );
      expect(
        world
            .shapeCast(
              shape: const SphereShape(.2),
              pose: PhysicsPose(position: const Vec3(3, 5, 0)),
              velocity: const Vec3(0, -10, 0),
              filter: const QueryFilter(excludeSensors: true),
            )!
            .time,
        closeTo(.48, .03),
      );
      expect(
        world.overlap(
          shape: const SphereShape(1),
          pose: PhysicsPose(position: const Vec3(0, .5, 0)),
        ),
        isNotEmpty,
      );
      expect(world.debugLines(), isNotEmpty);
      ball.remove();
      expect(() => ball.wake(), throwsStateError);
    } finally {
      world.close();
      world.close();
    }
    expect(PhysicsWorld.nativeCounts, baseline);
  });
  test('world isolation, validation, snapshot and stale handles', () {
    final a = PhysicsWorld(gravity: Vec3.zero), b = PhysicsWorld();
    try {
      final body = a.createBody();
      body.addCollider(const SphereShape(1));
      expect(
        () => body.addCollider(const SphereShape(-1)),
        throwsA(isA<PhysicsException>()),
      );
      expect(
        () => b.createJoint(
          body1: body,
          body2: b.createBody(),
          kind: JointKind.fixed,
        ),
        throwsStateError,
      );
      body.setVelocity(const Vec3(1, 0, 0));
      a.step();
      final snapshot = a.snapshot(), position = body.state.pose.position;
      for (var i = 0; i < 10; i++) {
        a.step();
      }
      a.restore(PhysicsSnapshot.decode(snapshot.encode()));
      expect(() => body.wake(), throwsStateError);
      final restored = a.body(body.id, BodyKind.dynamic);
      expect(restored.state.pose.position, position);
      a.step();
      expect(restored.state.pose.position.x, greaterThan(position.x));
      expect(b.states.length, 1);
    } finally {
      a.close();
      b.close();
    }
  });
  test('all shapes and body restrictions', () {
    final w = PhysicsWorld(gravity: Vec3.zero);
    try {
      final vertices = [
        const Vec3(0, 0, 0),
        const Vec3(1, 0, 0),
        const Vec3(0, 1, 0),
        const Vec3(0, 0, 1),
      ];
      final mesh = TriangleMeshShape(vertices, [
        [0, 1, 2],
        [0, 2, 3],
      ]);
      final fixed = w.createBody(kind: BodyKind.fixed);
      fixed.addCollider(mesh);
      final body = w.createBody();
      body.addCollider(ConvexShape(vertices));
      body.addCollider(const CapsuleShape(halfHeight: .5, radius: .2));
      body.addCollider(
        CompoundShape([
          CompoundChild(const SphereShape(.1)),
          CompoundChild(
            const BoxShape(Vec3(.1, .1, .1)),
            pose: PhysicsPose(position: const Vec3(0, 1, 0)),
          ),
        ]),
      );
      expect(() => body.addCollider(mesh), throwsA(isA<PhysicsException>()));
      w.step();
      expect(w.debugLines(), isNotEmpty);
    } finally {
      w.close();
    }
  });
  test('kinematic modes, impulses, forces, sleep and joints', () {
    final w = PhysicsWorld(gravity: Vec3.zero);
    try {
      final anchor = w.createBody(kind: BodyKind.fixed);
      for (final kind in JointKind.values) {
        final body = w.createBody(
          pose: PhysicsPose(position: const Vec3(0, 1, 0)),
        );
        body.addCollider(const SphereShape(.1));
        final joint = w.createJoint(
          body1: anchor,
          body2: body,
          kind: kind,
          length: 1,
          limits: kind == JointKind.hinge || kind == JointKind.slider
              ? [-.5, .5]
              : null,
          motorVelocity: (kind == JointKind.hinge || kind == JointKind.slider)
              ? .2
              : null,
        );
        for (var i = 0; i < 10; i++) {
          w.step();
        }
        expect(body.state.pose.position.isFinite, isTrue);
        joint.remove();
        body.remove();
      }
      final k = w.createBody(kind: BodyKind.kinematicPosition);
      k.addCollider(const SphereShape(.1));
      k.setTarget(PhysicsPose(position: const Vec3(1, 0, 0)));
      w.step();
      expect(k.state.pose.position.x, closeTo(1, 1e-5));
      final v = w.createBody(kind: BodyKind.kinematicVelocity);
      v.setVelocity(const Vec3(1, 0, 0));
      w.step();
      expect(v.state.pose.position.x, greaterThan(0));
      expect(
        () => v.setTarget(PhysicsPose()),
        throwsA(isA<PhysicsException>()),
      );
      final d = w.createBody(mass: 2, inertia: Vec3.one);
      d.addCollider(const SphereShape(.1), density: 0);
      w.step();
      d.applyImpulse(const Vec3(2, 0, 0));
      d.applyTorqueImpulse(const Vec3(0, 1, 0));
      w.step();
      expect(d.state.velocity.x, closeTo(1, 1e-4));
      d.addForce(const Vec3(1, 0, 0));
      d.addTorque(const Vec3(0, 1, 0));
      w.step();
      d.clearForces();
      d.sleep();
      expect(d.state.sleeping, isTrue);
      d.wake();
      expect(d.state.sleeping, isFalse);
      d.teleport(PhysicsPose());
      expect(d.state.velocity, Vec3.zero);
    } finally {
      w.close();
    }
  });
}
