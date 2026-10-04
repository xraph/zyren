import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean_physics/zyren_geospatial_ocean_physics.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support.dart';

void main() {
  test(
    'pending detach cancels only that actor and close preserves other force sources',
    () async {
      final world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81)),
          frame = worldFrame();
      var instant = GeoInstant(tick: 1, hz: 60, epoch: epoch);
      final sampler = await OceanSamplerCpu.create(
        state: calmSea(),
        frame: frame,
        now: () => instant,
        coverage: const OceanAllWaterCoverage(),
      );
      final bridge = OceanPhysicsBridge(
        world: world,
        sampler: sampler,
        policy: OceanQueryPolicy(),
        density: 1000,
      );
      try {
        final a = cube(world), b = cube(world, position: const Vec3(10, 0, 0));
        bridge.bind(a, cubeShape());
        final binding = bridge.bind(b, cubeShape());
        bridge.apply(await bridge.prepare(instant), 1 / 60);
        binding.dispose();
        instant = instant.withTick(2);
        await expectLater(bridge.prepare(instant), throwsStateError);
        world.step();
        expect(a.state.velocity.z.abs(), lessThan(1e-6));
        expect(b.state.velocity.z, lessThan(-.1));
        bridge.apply(await bridge.prepare(instant), 1 / 60);
        world.queueForces([
          PhysicsForce(a, force: const Vec3(4000, 0, 0)),
        ], expectedRevision: world.revision);
        await bridge.close();
        world.step();
        expect(a.state.velocity.x, closeTo(1 / 60, 1e-6));
        expect(a.state.velocity.z, lessThan(-.1));
      } finally {
        await bridge.close();
        await sampler.close();
        world.close();
      }
    },
  );

  test(
    'bridge applies one additive batch without stepping or closing its owners',
    () async {
      final world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81)),
          frame = worldFrame();
      var instant = GeoInstant(tick: 1, hz: 60, epoch: epoch);
      final sampler = await OceanSamplerCpu.create(
        state: calmSea(),
        frame: frame,
        now: () => instant,
        coverage: const OceanAllWaterCoverage(),
      );
      final bridge = OceanPhysicsBridge(
        world: world,
        sampler: sampler,
        policy: OceanQueryPolicy(),
        density: 1000,
      );
      try {
        final body = cube(world),
            binding = bridge.bind(
              cube(world, position: const Vec3(10, 0, 0)),
              cubeShape(),
            );
        bridge.bind(body, cubeShape());
        body.addForce(const Vec3(4000, 0, 0));
        final before = body.state.pose.position,
            batch = await bridge.prepare(instant);
        bridge.apply(batch, 1 / 60);
        expect(body.state.pose.position, before);
        expect(body.state.velocity, Vec3.zero);
        expect(() => bridge.apply(batch, 1 / 60), throwsStateError);
        world.step();
        expect(body.state.velocity.x, closeTo(1 / 60, 1e-6));
        expect(body.state.velocity.z.abs(), lessThan(1e-6));
        expect(body.state.pose.position.z.abs(), lessThan(1e-6));
        binding.dispose();
        instant = instant.withTick(2);
        expect((await bridge.prepare(instant)).bodies.length, 1);
      } finally {
        await bridge.close();
        await sampler.close();
        world.close();
      }
    },
  );
  test(
    'cargo, detach and world changes reject the whole prepared batch',
    () async {
      final world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81)),
          frame = worldFrame();
      final instant = GeoInstant(tick: 1, hz: 60, epoch: epoch);
      final sampler = await OceanSamplerCpu.create(
        state: calmSea(),
        frame: frame,
        now: () => instant,
        coverage: const OceanAllWaterCoverage(),
      );
      final bridge = OceanPhysicsBridge(
        world: world,
        sampler: sampler,
        policy: OceanQueryPolicy(),
        density: 1000,
      );
      try {
        final a = cube(world), b = cube(world, position: const Vec3(10, 0, 0));
        bridge.bind(a, cubeShape());
        final binding = bridge.bind(b, cubeShape());
        var batch = await bridge.prepare(instant);
        b.setMassProperties(
          mass: 100,
          inertia: Vec3.one,
          centerOfMass: const Vec3(1, 0, 0),
        );
        expect(() => bridge.apply(batch, 1 / 60), throwsStateError);
        expect(a.state.velocity, Vec3.zero);
        expect(b.state.velocity, Vec3.zero);
        batch = await bridge.prepare(instant);
        binding.dispose();
        expect(() => bridge.apply(batch, 1 / 60), throwsStateError);
        batch = await bridge.prepare(instant);
        world.step();
        expect(() => bridge.apply(batch, 1 / 60), throwsStateError);
      } finally {
        await bridge.close();
        await sampler.close();
        world.close();
      }
    },
  );
}
