import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test(
    'batch matches scalar rays with ordered misses and normalized distances',
    () {
      final world = PhysicsWorld(gravity: Vec3.zero);
      try {
        final body = world.createBody(kind: BodyKind.fixed);
        body.addCollider(const SphereShape(1));
        const rays = [
          PhysicsRay(origin: Vec3(0, 0, 3), direction: Vec3(0, 0, -5)),
          PhysicsRay(origin: Vec3(4, 0, 3), direction: Vec3(0, 0, -1)),
          PhysicsRay(origin: Vec3.zero, direction: Vec3(1, 0, 0)),
          PhysicsRay(origin: Vec3.zero, direction: Vec3(1, 0, 0), solid: false),
          PhysicsRay(
            origin: Vec3(0, 0, 3),
            direction: Vec3(0, 0, -1),
            maxDistance: 1,
          ),
        ];
        final before = world.revision;
        final hits = world.rayCastBatch(rays);
        expect(world.revision, before + 1);
        for (var i = 0; i < rays.length; i++) {
          final ray = rays[i];
          final scalar = world.rayCast(
            origin: ray.origin,
            direction: ray.direction,
            maxDistance: ray.maxDistance,
            solid: ray.solid,
          );
          expect(hits[i]?.collider, scalar?.collider);
          expect(hits[i]?.body, scalar?.body);
          expect(hits[i]?.time, scalar?.time);
          expect(hits[i]?.normal, scalar?.normal);
        }
        expect(hits[0]!.time, 2);
        expect(hits[1], isNull);
      expect(hits[2]!.time, 0);
      expect(hits[2]!.normal, Vec3.zero);
        expect(hits[3]!.time, 1);
        expect(hits[4], isNull);
        expect(() => hits.clear(), throwsUnsupportedError);
        body.teleport(PhysicsPose(position: const Vec3(0, 0, -4)));
        expect(world.rayCastBatch([rays.first]).single!.time, 6);
      } finally {
        world.close();
      }
    },
  );

  test('shared filters exclude sensors, bodies and collision groups', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      PhysicsBody sphere(double z, {bool sensor = false, int group = 1}) {
        final body = world.createBody(
          kind: BodyKind.fixed,
          pose: PhysicsPose(position: Vec3(0, 0, z)),
        );
        body.addCollider(
          const SphereShape(.25),
          sensor: sensor,
          membership: group,
        );
        return body;
      }

      sphere(3, sensor: true);
      final excluded = sphere(2);
      sphere(1, group: 2);
      final accepted = sphere(0);
      final hit = world.rayCastBatch(
        const [PhysicsRay(origin: Vec3(0, 0, 5), direction: Vec3(0, 0, -1))],
        filter: QueryFilter(
          excludeSensors: true,
          excludeBody: excluded,
          filter: 1,
        ),
      ).single!;
      expect(hit.body, accepted.id);
      expect(hit.time, closeTo(4.75, 1e-6));
    } finally {
      world.close();
    }
  });

  test('query refresh retains one collision transition without stepping', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    try {
      world
          .createBody(kind: BodyKind.fixed)
          .addCollider(const SphereShape(2), sensor: true);
      world.createBody().addCollider(const SphereShape(.5));
      world.rayCastBatch(
        List.filled(
          256,
          const PhysicsRay(origin: Vec3(0, 5, 0), direction: Vec3(0, -1, 0)),
        ),
      );
      expect(
        world.drainEvents().where((e) => e.sensor && e.started),
        hasLength(1),
      );
      expect(world.drainEvents(), isEmpty);
      expect(world.states.last.pose.position, Vec3.zero);
    } finally {
      world.close();
    }
  });

  test('invalid batches and foreign or stale exclusions fail explicitly', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    final other = PhysicsWorld(gravity: Vec3.zero);
    const ray = PhysicsRay(origin: Vec3.zero, direction: Vec3(0, 0, -1));
    try {
      expect(world.rayCastBatch([]), isEmpty);
      expect(
        () => world.rayCastBatch(List.filled(257, ray)),
        throwsArgumentError,
      );
      expect(
        () => world.rayCastBatch([
          ray,
          const PhysicsRay(origin: Vec3.zero, direction: Vec3.zero),
        ]),
        throwsA(isA<PhysicsException>()),
      );
      expect(
        () => world.rayCastBatch([
          const PhysicsRay(
            origin: Vec3.zero,
            direction: Vec3(0, 0, -1),
            maxDistance: -1,
          ),
        ]),
        throwsA(isA<PhysicsException>()),
      );
      expect(
        () => world.rayCastBatch([
          ray,
        ], filter: QueryFilter(excludeBody: other.createBody())),
        throwsStateError,
      );
      final body = world.createBody();
      world.restore(world.snapshot());
      expect(
        () => world.rayCastBatch([ray], filter: QueryFilter(excludeBody: body)),
        throwsStateError,
      );
      world.close();
      expect(() => world.rayCastBatch([]), throwsStateError);
    } finally {
      world.close();
      other.close();
    }
  });
}
