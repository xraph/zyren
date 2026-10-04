import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test(
    'checkpoint restores position-kinematic derived velocities without changing kind or targets',
    () {
      final world = PhysicsWorld(gravity: Vec3.zero, fixedStep: 1 / 60);
      try {
        final body = world.createBody(
          kind: BodyKind.kinematicPosition,
          mass: 3,
          inertia: Vec3.one,
        );
        final collider = body.addCollider(const SphereShape(.2));
        final bodyId = body.id, mass = body.state.mass;
        final counts = PhysicsWorld.nativeCounts;
        body.restoreMotion(
          pose: PhysicsPose(position: const Vec3(0, 1, 0)),
          velocity: const Vec3(1, -2, 3),
          angularVelocity: const Vec3(.1, .2, .3),
          sleeping: false,
        );
        expect(body.state.velocity, const Vec3(1, -2, 3));
        expect(
          body.state.angularVelocity.distanceTo(const Vec3(.1, .2, .3)),
          lessThan(1e-6),
        );
        expect(body.state.kind, BodyKind.kinematicPosition);
        expect(body.id, bodyId);
        expect(body.state.mass, mass);
        expect(
          world
              .rayCast(
                origin: const Vec3(0, 1, -2),
                direction: const Vec3(0, 0, 1),
              )!
              .collider,
          collider.id,
        );
        expect(PhysicsWorld.nativeCounts, counts);
        final before = body.state.pose.position;
        expect(
          () => body.restoreMotion(
            pose: PhysicsPose(position: const Vec3(100, 0, 0)),
            velocity: const Vec3(1e20, 0, 0),
            angularVelocity: Vec3.zero,
            sleeping: false,
          ),
          throwsA(isA<PhysicsException>()),
        );
        expect(body.state.pose.position, before);
        expect(body.state.velocity, const Vec3(1, -2, 3));
        expect(
          () => body.restoreMotion(
            pose: PhysicsPose(position: const Vec3(100, 0, 0)),
            velocity: Vec3.one,
            angularVelocity: Vec3.zero,
            sleeping: true,
          ),
          throwsA(isA<PhysicsException>()),
        );
        expect(body.state.pose.position, before);
        expect(body.state.velocity, const Vec3(1, -2, 3));
        body.setTarget(PhysicsPose(position: const Vec3(0, 1, 1)));
        world.step();
        expect(body.state.pose.position.z, closeTo(1, 1e-6));
        expect(body.state.kind, BodyKind.kinematicPosition);
        expect(body.state.velocity.z, closeTo(60, 1e-4));
      } finally {
        world.close();
      }
    },
  );

  test('fixed checkpoint rejection validates before changing pose', () {
    final world = PhysicsWorld();
    try {
      final body = world.createBody(kind: BodyKind.fixed);
      expect(
        () => body.restoreMotion(
          pose: PhysicsPose(position: const Vec3(100, 0, 0)),
          velocity: Vec3.one,
          angularVelocity: Vec3.zero,
          sleeping: false,
        ),
        throwsA(isA<PhysicsException>()),
      );
      expect(body.state.pose.position, Vec3.zero);
    } finally {
      world.close();
    }
  });
}
