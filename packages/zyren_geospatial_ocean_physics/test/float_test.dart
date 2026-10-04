import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean_physics/zyren_geospatial_ocean_physics.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support.dart';

Future<BodyState> floatCube(
  int hz, {
  double seconds = 8,
  double startHeight = .4,
}) async {
  final world = PhysicsWorld(
        gravity: const Vec3(0, 0, -9.81),
        fixedStep: 1 / hz,
      ),
      frame = worldFrame();
  var instant = GeoInstant(tick: 0, hz: hz, epoch: epoch);
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
    final body = cube(world, position: Vec3(0, 0, startHeight));
    bridge.bind(
      body,
      cubeShape(),
      solver: BuoyancySolver(
        drag: BuoyancyDrag(linear: 1000, quadratic: 500, angular: 1000),
      ),
    );
    for (var tick = 1; tick <= (seconds * hz).round(); tick++) {
      instant = instant.withTick(tick);
      bridge.apply(await bridge.prepare(instant), world.fixedStep);
      world.step();
    }
    return body.state;
  } finally {
    await bridge.close();
    await sampler.close();
    world.close();
  }
}

void main() {
  test(
    'native cube settles at half displacement with step convergence',
    () async {
      final states = [
        for (final hz in [30, 60, 120]) await floatCube(hz),
      ];
      for (final state in states) {
        expect(state.pose.position.z.abs(), lessThan(.02));
        expect(state.velocity.length, lessThan(.04));
      }
      final coarse = states[0].pose.position.distanceTo(
        states[2].pose.position,
      );
      final fine = states[1].pose.position.distanceTo(states[2].pose.position);
      expect(coarse, lessThan(.01));
      expect(fine, lessThan(.005));
    },
  );
  test(
    'four pontoons settle, heel under asymmetric cargo and keep separate density',
    () async {
      final world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81)),
          frame = worldFrame();
      var instant = GeoInstant(tick: 0, hz: 60, epoch: epoch);
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
        final shape = vesselShape(), mass = 1000 * math.pi / 3;
        final body = world.createBody(
          mass: mass,
          inertia: const Vec3(3000, 6000, 8000),
          pose: PhysicsPose(
            position: const Vec3(0, 0, .3),
            rotation: Quat.axisAngle(const Vec3(0, 1, 0), .15),
          ),
        );
        body.addCollider(const BoxShape(Vec3(2.5, 1.5, .5)), density: 0);
        bridge.bind(
          body,
          shape,
          solver: BuoyancySolver(
            drag: BuoyancyDrag(linear: 1200, quadratic: 500, angular: 3000),
          ),
        );
        final heavy = cube(
          world,
          density: 1500,
          position: const Vec3(15, 0, 0),
        );
        bridge.bind(
          heavy,
          cubeShape(),
          solver: BuoyancySolver(drag: BuoyancyDrag(linear: 100)),
        );
        Future<void> ticks(int count) async {
          for (var i = 0; i < count; i++) {
            instant = instant.withTick(instant.tick + 1);
            bridge.apply(await bridge.prepare(instant), world.fixedStep);
            world.step();
          }
        }

        await ticks(600);
        expect(body.state.pose.position.z.abs(), lessThan(.02));
        expect(
          body.state.pose.rotation.rotate(const Vec3(0, 0, 1)).x.abs(),
          lessThan(.02),
        );
        expect(heavy.state.pose.position.z, lessThan(-5));
        body.setMassProperties(
          mass: mass + 200,
          inertia: const Vec3(3000, 6000, 8000),
          centerOfMass: const Vec3(.3, 0, 0),
        );
        await ticks(600);
        expect(
          body.state.pose.rotation.rotate(const Vec3(0, 0, 1)).x,
          greaterThan(.015),
        );
        expect(body.state.pose.position.z, lessThan(-.01));
      } finally {
        await bridge.close();
        await sampler.close();
        world.close();
      }
    },
  );
  test(
    'balanced sleep, dry wake and current-driven motion use explicit policy',
    () async {
      final world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81)),
          frame = worldFrame(),
          current = FixtureCurrent();
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
        current: current,
        density: 1000,
      );
      try {
        final body = cube(world)..sleep();
        bridge.bind(
          body,
          cubeShape(),
          solver: BuoyancySolver(drag: BuoyancyDrag(linear: 1000)),
        );
        var batch = await bridge.prepare(instant);
        expect(batch.bodies.single.preserveSleep, isTrue);
        bridge.apply(batch, 1 / 60);
        world.step();
        expect(body.state.sleeping, isTrue);
        body.teleport(PhysicsPose(position: const Vec3(0, 0, 3)));
        body.sleep();
        instant = instant.withTick(2);
        bridge.apply(await bridge.prepare(instant), 1 / 60);
        world.step();
        expect(body.state.sleeping, isFalse);
        expect(body.state.velocity.z, lessThan(0));
        body.teleport(PhysicsPose());
        body.sleep();
        instant = instant.withTick(3);
        current.velocity = frame.vectorToEcef(const Vec3(2, 0, 0));
        current.revision = 'two';
        batch = await bridge.prepare(instant);
        bridge.apply(batch, 1 / 60);
        world.step();
        expect(body.state.sleeping, isFalse);
        expect(body.state.velocity.x, greaterThan(0));
        expect(body.state.velocity.x, lessThan(2));
        instant = instant.withTick(4);
        batch = await bridge.prepare(instant);
        current.revision = 'three';
        expect(() => bridge.apply(batch, 1 / 60), throwsStateError);
        current.available = false;
        await expectLater(bridge.prepare(instant), throwsStateError);
      } finally {
        await bridge.close();
        await sampler.close();
        world.close();
      }
    },
  );
}
