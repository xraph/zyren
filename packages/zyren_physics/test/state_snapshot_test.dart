import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test('body reads share completed state until native mutation or restore', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    final other = PhysicsWorld(gravity: Vec3.zero);
    try {
      final body = world.createBody(velocity: const Vec3(1, 0, 0));
      final collider = body.addCollider(const SphereShape(.5));
      final first = body.state;
      expect(identical(body.state, first), isTrue);
      final step = world.step();
      expect(identical(body.state, step.bodies.single), isTrue);
      final stepped = body.state;
      body.setVelocity(const Vec3(3, 0, 0));
      expect(body.state.velocity, const Vec3(3, 0, 0));
      expect(stepped.velocity, const Vec3(1, 0, 0));
      final beforeDensity = body.state;
      collider.configure(density: 2);
      expect(identical(body.state, beforeDensity), isFalse);
      // Rapier recomputes density-derived mass at the next simulation step.
      world.step();
      expect(body.state.mass, greaterThan(beforeDensity.mass));
      final beforeFailure = body.state;
      expect(
        () => body.setDamping(linear: -1),
        throwsA(isA<PhysicsException>()),
      );
      expect(identical(body.state, beforeFailure), isFalse);
      final snapshot = world.snapshot(), id = body.id;
      world.restore(snapshot);
      expect(() => body.state, throwsStateError);
      final restored = world.body(id);
      expect(restored.state.velocity, const Vec3(3, 0, 0));
      final foreign = other.createBody();
      expect(foreign.id, id);
      expect(foreign.state.velocity, Vec3.zero);
      restored.remove();
      expect(() => restored.state, throwsStateError);
      world.close();
      expect(() => world.body(id), throwsStateError);
    } finally {
      world.close();
      other.close();
    }
  });
  test('step snapshots stay immutable across fresh native body writes', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final body = world.createBody(velocity: const Vec3(1, 0, 0));
      final collider = body.addCollider(const SphereShape(.5));
      final step = world.step();
      final snapshot = world.states;
      expect(identical(snapshot, step.bodies), isTrue);
      expect(() => snapshot.clear(), throwsUnsupportedError);
      final oldPosition = snapshot.single.pose.position;
      body.teleport(PhysicsPose(position: const Vec3(4, 2, 1)));
      expect(world.states.single.pose.position, body.state.pose.position);
      expect(snapshot.single.pose.position, oldPosition);
      body.setVelocity(const Vec3(2, 3, 4));
      expect(world.states.single.velocity, body.state.velocity);
      body.setAngularVelocity(const Vec3(.1, .2, .3));
      expect(world.states.single.angularVelocity, body.state.angularVelocity);
      body.setMassProperties(mass: 3, inertia: Vec3.one);
      expect(world.states.single.mass, body.state.mass);
      collider.configure(density: 2);
      expect(world.states.single.mass, body.state.mass);
      body.sleep();
      expect(world.states.single.sleeping, isTrue);
      body.wake();
      expect(world.states.single.sleeping, isFalse);
      body.applyImpulse(const Vec3(2, 0, 0));
      expect(world.states.single.velocity, body.state.velocity);
      final next = world.step();
      expect(identical(world.states, next.bodies), isTrue);
      expect(world.states.single.pose.position, body.state.pose.position);
    } finally {
      world.close();
    }
    expect(() => world.states, throwsStateError);
  });

  test('queries, failed writes and topology changes discard snapshots', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final body = world.createBody();
      body.addCollider(const SphereShape(.5));
      var before = world.step().bodies;
      world.rayCast(
        origin: const Vec3(0, 0, 2),
        direction: const Vec3(0, 0, -1),
      );
      expect(identical(world.states, before), isFalse);
      expect(world.states.single.mass, body.state.mass);
      before = world.states;
      expect(
        () => body.setDamping(linear: -1),
        throwsA(isA<PhysicsException>()),
      );
      expect(identical(world.states, before), isFalse);
      expect(world.states.single.velocity, body.state.velocity);
      final saved = world.snapshot();
      final id = body.id;
      final extra = world.createBody();
      expect(world.states.length, 2);
      extra.remove();
      expect(world.states.length, 1);
      body.teleport(PhysicsPose(position: const Vec3(10, 0, 0)));
      expect(world.states.single.pose.position.x, 10);
      world.restore(saved);
      expect(body.isAlive, isFalse);
      expect(world.states.single.pose.position, Vec3.zero);
      final restored = world.body(id);
      expect(world.states.single.pose.position, restored.state.pose.position);
      restored.remove();
      expect(world.states, isEmpty);
    } finally {
      world.close();
    }
  });

  test('read-only diagnostics preserve a completed simulation snapshot', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      final body = world.createBody();
      final snapshot = world.step().bodies;
      body.state;
      world.snapshot();
      world.debugLines();
      world.drainEvents();
      expect(identical(world.states, snapshot), isTrue);
    } finally {
      world.close();
    }
  });
}
