import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

KinematicCharacterController character(PhysicsWorld world) {
  world
      .createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(0, -.5, 0)),
      )
      .addCollider(const BoxShape(Vec3(10, .5, 10)));
  world
      .createBody(
        kind: BodyKind.fixed,
        pose: PhysicsPose(position: const Vec3(1, 1, 0)),
      )
      .addCollider(const BoxShape(Vec3(.1, 1, 5)));
  final body = world.createBody(
    kind: BodyKind.kinematicPosition,
    pose: PhysicsPose(
      position: const Vec3(0, .81, 0),
      rotation: Quat.axisAngle(const Vec3(0, 1, 0), .3),
    ),
  );
  return KinematicCharacterController(
    body: body,
    collider: body.addCollider(
      const CapsuleShape(halfHeight: .5, radius: .3),
      offset: PhysicsPose(position: const Vec3(.1, 0, 0)),
    ),
  );
}

void vectorNear(Vec3 a, Vec3 b, [double tolerance = 2e-6]) {
  expect(a.x, closeTo(b.x, tolerance));
  expect(a.y, closeTo(b.y, tolerance));
  expect(a.z, closeTo(b.z, tolerance));
}

void main() {
  test(
    'atomic target matches separate resolve and target through 600 steps',
    () {
      final scalar = PhysicsWorld(fixedStep: .02);
      final atomic = PhysicsWorld(fixedStep: .02);
      try {
        final a = character(scalar), b = character(atomic);
        for (var tick = 0; tick < 600; tick++) {
          final desired = Vec3(
            math.sin(tick * .04) * .03,
            -.01,
            math.cos(tick * .04) * .03,
          );
          final rotation = tick % 3 == 0
              ? Quat.axisAngle(const Vec3(0, 1, 0), tick * .007)
              : null;
          final before = a.body.state.pose;
          final resolved = a.resolve(desired);
          a.body.setTarget(
            PhysicsPose(
              position: before.position + resolved.translation,
              rotation: rotation ?? before.rotation,
            ),
          );
          final atomicBefore = b.body.state.pose;
          expect(atomicBefore.json, before.json, reason: 'before tick $tick');
          final combined = b.move(desired, rotation: rotation);
          expect(b.body.state.pose.position, atomicBefore.position);
          vectorNear(combined.translation, resolved.translation);
          expect(combined.grounded, resolved.grounded);
          expect(combined.sliding, resolved.sliding);
          expect(
            combined.contacts.map((c) => c.collider),
            resolved.contacts.map((c) => c.collider),
          );
          for (var i = 0; i < combined.contacts.length; i++) {
            vectorNear(combined.contacts[i].point, resolved.contacts[i].point);
            vectorNear(
              combined.contacts[i].normal,
              resolved.contacts[i].normal,
            );
          }
          scalar.step();
          atomic.step();
          final x = a.body.state, y = b.body.state;
          vectorNear(x.pose.position, y.pose.position);
          vectorNear(x.velocity, y.velocity, 1e-4);
          vectorNear(
            x.pose.rotation.rotate(const Vec3(0, 0, 1)),
            y.pose.rotation.rotate(const Vec3(0, 0, 1)),
          );
        }
      } finally {
        scalar.close();
        atomic.close();
      }
    },
  );

  test('failed target admission preserves the previous valid target', () {
    final world = PhysicsWorld(gravity: Vec3.zero, fixedStep: .02);
    try {
      final c = character(world);
      final before = c.body.state.pose;
      final accepted = c.move(const Vec3(.02, 0, .01));
      expect(
        () => c.move(const Vec3(1, 0, 0), rotation: const Quat(0, 0, 0, 0)),
        throwsArgumentError,
      );
      expect(
        () => c.move(const Vec3(10000, 0, 0)),
        throwsA(isA<PhysicsException>()),
      );
      world.step();
      vectorNear(
        c.body.state.pose.position,
        before.position + accepted.translation,
      );
      final saved = world.snapshot();
      world.restore(saved);
      expect(() => c.move(Vec3.zero), throwsStateError);
    } finally {
      world.close();
    }
  });

  test('resolve stays query-only and move keeps orientation when omitted', () {
    final world = PhysicsWorld(gravity: Vec3.zero, fixedStep: .02);
    try {
      final c = character(world);
      final before = c.body.state.pose;
      c.resolve(const Vec3(.02, 0, 0));
      world.step();
      expect(c.body.state.pose.position, before.position);
      c.move(const Vec3(.02, 0, 0));
      world.step();
      expect(c.body.state.pose.position.x, greaterThan(before.position.x));
      vectorNear(
        c.body.state.pose.rotation.rotate(const Vec3(0, 0, 1)),
        before.rotation.rotate(const Vec3(0, 0, 1)),
      );
      c.collider.remove();
      expect(() => c.move(Vec3.zero), throwsStateError);
    } finally {
      world.close();
    }
  });

  test('target obeys transient-force mutation admission', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final c = character(world);
      final dynamicBody = world.createBody(mass: 1, inertia: Vec3.one);
      final forces = world.queueForces([
        PhysicsForce(dynamicBody, force: const Vec3(1, 0, 0)),
      ], expectedRevision: world.revision);
      final before = c.body.state.pose;
      c.resolve(const Vec3(.01, 0, 0));
      expect(
        () => c.move(const Vec3(.01, 0, 0)),
        throwsA(isA<PhysicsException>()),
      );
      world.step();
      expect(c.body.state.pose.position, before.position);
      forces.dispose();
      c.move(const Vec3(.01, 0, 0));
      world.step();
      expect(c.body.state.pose.position.x, greaterThan(before.position.x));
    } finally {
      world.close();
    }
  });
}
