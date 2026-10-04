import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test('rigid world rebase preserves motion, external forces and gravity', () {
    final world = PhysicsWorld(gravity: const Vec3(0, 0, -10));
    try {
      final body = world.createBody(
        mass: 2,
        inertia: Vec3.one,
        pose: PhysicsPose(position: const Vec3(1, 2, 3)),
        velocity: const Vec3(1, 0, 0),
        angularVelocity: const Vec3(0, 0, 1),
      );
      body.addForce(const Vec3(2, 0, 0));
      body.addTorque(const Vec3(0, 2, 0));
      final transform = PhysicsPose(
        position: const Vec3(10, 20, 30),
        rotation: Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2),
      );
      final before = body.state;
      world.rebase(transform, expectedRevision: world.revision);
      final after = body.state;
      expect(
        after.pose.position.distanceTo(
          transform.position + transform.rotation.rotate(before.pose.position),
        ),
        lessThan(1e-5),
      );
      expect(
        after.velocity.distanceTo(transform.rotation.rotate(before.velocity)),
        lessThan(1e-6),
      );
      expect(
        after.angularVelocity.distanceTo(
          transform.rotation.rotate(before.angularVelocity),
        ),
        lessThan(1e-6),
      );
      expect(world.gravity.distanceTo(const Vec3(-10, 0, 0)), lessThan(1e-5));
      world.step();
      final expected =
          after.velocity +
          (const Vec3(-10, 0, 0) +
                  transform.rotation.rotate(const Vec3(1, 0, 0))) *
              world.fixedStep;
      expect(body.state.velocity.distanceTo(expected), lessThan(1e-5));
      expect(body.state.angularVelocity.y, closeTo(2 * world.fixedStep, 1e-5));
    } finally {
      world.close();
    }
  });

  test('compound mass, COM and inertia refresh before stepping', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final body = world.createBody(
        pose: PhysicsPose(position: const Vec3(10, 0, 0)),
      );
      final collider = body.addCollider(
        CompoundShape([
          CompoundChild(
            const BoxShape(Vec3.one),
            pose: PhysicsPose(position: const Vec3(-2, 0, 0)),
          ),
          CompoundChild(
            const BoxShape(Vec3.one),
            pose: PhysicsPose(position: const Vec3(2, 0, 0)),
          ),
        ]),
        density: 3,
      );
      final initial = body.state;
      expect(initial.mass, closeTo(48, 1e-5));
      expect(initial.localCenterOfMass.length, lessThan(1e-6));
      expect(
        initial.centerOfMass.distanceTo(const Vec3(10, 0, 0)),
        lessThan(1e-6),
      );
      expect(
        initial.inverseInertia.apply(const Vec3(1, 0, 0)).x,
        closeTo(1 / 32, 1e-6),
      );
      expect(
        initial.inverseInertia.apply(const Vec3(0, 1, 0)).y,
        closeTo(1 / 224, 1e-6),
      );
      collider.configure(density: 6);
      expect(body.state.mass, closeTo(96, 1e-5));
      expect(
        body.state.massPropertiesRevision,
        greaterThan(initial.massPropertiesRevision),
      );
      body.setMassProperties(
        mass: 96,
        inertia: Vec3.one,
        centerOfMass: const Vec3(4, 0, 0),
      );
      expect(body.state.mass, closeTo(192, 1e-5));
      expect(body.state.localCenterOfMass.x, closeTo(2, 1e-6));
      expect(body.state.centerOfMass.x, closeTo(12, 1e-6));
      collider.remove();
      expect(body.state.mass, closeTo(96, 1e-5));
      expect(body.state.localCenterOfMass.x, closeTo(4, 1e-6));
      body.teleport(
        PhysicsPose(
          position: const Vec3(1, 2, 3),
          rotation: Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2),
        ),
      );
      expect(
        body.state.centerOfMass.distanceTo(const Vec3(1, 6, 3)),
        lessThan(1e-5),
      );
    } finally {
      world.close();
    }
  });
  test('world inverse inertia predicts the actual native angular impulse', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final body = world.createBody(
        mass: 5,
        inertia: const Vec3(2, 3, 7),
        pose: PhysicsPose(rotation: Quat.axisAngle(const Vec3(1, 2, 3), .7)),
      );
      final state = body.state, impulse = const Vec3(1, 2, 3);
      final expected = state.inverseInertia.apply(impulse);
      body.applyTorqueImpulse(impulse);
      expect(body.state.angularVelocity.distanceTo(expected), lessThan(1e-6));
    } finally {
      world.close();
    }
  });
  test('atomic impulse admission leaves all bodies unchanged on failure', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final a = world.createBody(mass: 2, inertia: Vec3.one),
          b = world.createBody(mass: 3, inertia: Vec3.one);
      final revision = world.revision;
      expect(
        () => world.applyImpulses([
          PhysicsImpulse(a, linear: const Vec3(1, 0, 0)),
          PhysicsImpulse(b, linear: const Vec3(1e13, 0, 0)),
        ], expectedRevision: revision),
        throwsA(isA<PhysicsException>()),
      );
      expect(a.state.velocity, Vec3.zero);
      expect(b.state.velocity, Vec3.zero);
      expect(
        () => world.applyImpulses([
          PhysicsImpulse(a, linear: Vec3.one),
        ], expectedRevision: revision),
        throwsStateError,
      );
      final current = world.revision;
      world.applyImpulses([
        PhysicsImpulse(a, linear: const Vec3(2, 0, 0), at: const Vec3(0, 1, 0)),
        PhysicsImpulse(b, angular: const Vec3(0, 0, 3)),
      ], expectedRevision: current);
      expect(a.state.velocity, const Vec3(1, 0, 0));
      expect(a.state.angularVelocity, const Vec3(0, 0, -2));
      expect(b.state.angularVelocity, const Vec3(0, 0, 3));
      expect(world.revision, greaterThan(current));
      expect(world.gravity, Vec3.zero);
    } finally {
      world.close();
    }
  });
}
