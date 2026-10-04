import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test(
    'transient force balances gravity over substeps and is consumed once',
    () {
      final world = PhysicsWorld(gravity: const Vec3(0, 0, -10));
      try {
        final body = world.createBody(
          mass: 2,
          inertia: Vec3.one,
          canSleep: false,
        );
        body.addForce(const Vec3(2, 0, 0));
        world.queueForces([
          PhysicsForce(body, force: const Vec3(0, 0, 20)),
        ], expectedRevision: world.revision);
        expect(body.state.velocity, Vec3.zero);
        world.step();
        expect(world.completedSteps, 1);
        expect(body.state.pose.position.z.abs(), lessThan(1e-8));
        expect(body.state.velocity.z.abs(), lessThan(1e-8));
        expect(body.state.velocity.x, closeTo(1 / 60, 1e-7));
        world.step();
        expect(body.state.velocity.x, closeTo(2 / 60, 1e-7));
        expect(body.state.velocity.z, closeTo(-10 / 60, 1e-7));
      } finally {
        world.close();
      }
    },
  );
  test(
    'force scopes cancel independently and reject mutation before integration',
    () {
      final world = PhysicsWorld(gravity: Vec3.zero);
      try {
        final a = world.createBody(mass: 1, inertia: Vec3.one),
            b = world.createBody(mass: 1, inertia: Vec3.one);
        final first = world.queueForces([
          PhysicsForce(a, force: const Vec3(60, 0, 0)),
          PhysicsForce(b, force: const Vec3(60, 0, 0)),
        ], expectedRevision: world.revision);
        final second = world.queueForces([
          PhysicsForce(a, force: const Vec3(0, 60, 0)),
        ], expectedRevision: world.revision);
        expect(
          () => a.teleport(PhysicsPose(position: Vec3.one)),
          throwsA(isA<PhysicsException>()),
        );
        expect(() => world.snapshot(), throwsA(isA<PhysicsException>()));
        expect(a.state.pose.position, Vec3.zero);
        first.removeBody(a);
        second.dispose();
        a.addForce(const Vec3(0, 0, 60));
        world.step();
        expect(
          a.state.velocity.distanceTo(const Vec3(0, 0, 1)),
          lessThan(1e-6),
        );
        expect(
          b.state.velocity.distanceTo(const Vec3(1, 0, 0)),
          lessThan(1e-6),
        );
        first.dispose();
        world.snapshot();
      } finally {
        world.close();
      }
    },
  );
  test('invalid later command cannot publish a partial transient batch', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final body = world.createBody(mass: 1, inertia: Vec3.one);
      expect(
        () => world.queueForces([
          PhysicsForce(body, force: Vec3.one),
          PhysicsForce(body, torque: const Vec3(1e13, 0, 0)),
        ], expectedRevision: world.revision),
        throwsA(isA<PhysicsException>()),
      );
      world.step();
      expect(body.state.velocity, Vec3.zero);
      expect(body.state.angularVelocity, Vec3.zero);
    } finally {
      world.close();
    }
  });
}
