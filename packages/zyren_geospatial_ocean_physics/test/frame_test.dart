import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean_physics/zyren_geospatial_ocean_physics.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support.dart';

void main() {
  test(
    'local rebase preserves ECEF pose, motion and pending external loads',
    () async {
      final frame = worldFrame(),
          world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81));
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
        final body = cube(world)..setVelocity(const Vec3(1, 2, 0));
        body.addForce(const Vec3(4000, 0, 0));
        bridge.bind(body, cubeShape());
        final before = body.state,
            ecef = frame.toEcef(before.pose.position),
            velocity = frame.vectorToEcef(before.velocity);
        final batch = await bridge.prepare(instant);
        final event = frame.rebase(Geodetic(.00001, .00002));
        await expectLater(bridge.prepare(instant), throwsStateError);
        bridge.applyRebase(event);
        expect(
          frame.toEcef(body.state.pose.position).distanceTo(ecef),
          lessThan(2e-5),
        );
        expect(
          frame.vectorToEcef(body.state.velocity).distanceTo(velocity),
          lessThan(1e-6),
        );
        expect(() => bridge.apply(batch, 1 / 60), throwsStateError);
        expect(() => bridge.applyRebase(event), throwsStateError);
        final next = await bridge.prepare(instant);
        bridge.apply(next, 1 / 60);
        world.step();
        final after = frame.vectorToEcef(body.state.velocity);
        expect(
          (after - velocity).distanceTo(const Vec3(0, 1 / 60, 0)),
          lessThan(2e-5),
        );
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
    'close, detach, source changes and resets invalidate in-flight preparation',
    () async {
      for (final change in ['close', 'detach', 'source', 'reset', 'body']) {
        final frame = worldFrame(),
            world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81)),
            coverage = FixtureCoverage();
        var instant = GeoInstant(tick: 1, hz: 60, epoch: epoch);
        final sampler = await OceanSamplerCpu.create(
          state: calmSea(),
          frame: frame,
          now: () => instant,
          coverage: coverage,
        );
        final bridge = OceanPhysicsBridge(
          world: world,
          sampler: sampler,
          policy: OceanQueryPolicy(),
          density: 1000,
        );
        final gate = Completer<void>();
        coverage.gate = gate.future;
        try {
          final body = cube(world),
              binding = bridge.bind(
                cube(world, position: const Vec3(10, 0, 0)),
                cubeShape(),
              );
          bridge.bind(body, cubeShape());
          final pending = bridge.prepare(instant);
          final failed = expectLater(
            pending,
            throwsA(anyOf(isA<StateError>(), isA<ArgumentError>())),
          );
          await Future<void>.delayed(Duration.zero);
          Future<void>? closing;
          switch (change) {
            case 'close':
              closing = bridge.close();
            case 'detach':
              binding.dispose();
            case 'source':
              coverage.revision = 'two';
            case 'reset':
              instant = GeoInstant(
                tick: 1,
                hz: 60,
                epoch: epoch,
                generation: 1,
              );
            case 'body':
              body.setMassProperties(mass: 100, inertia: Vec3.one);
          }
          gate.complete();
          await failed;
          await closing;
          expect(body.state.velocity, Vec3.zero);
        } finally {
          if (!gate.isCompleted) gate.complete();
          await bridge.close();
          await sampler.close();
          world.close();
        }
      }
    },
  );
  test(
    'unavailable water pauses forces and replay requires reacquired body handles',
    () async {
      final frame = worldFrame(),
          world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81)),
          coverage = FixtureCoverage();
      var instant = GeoInstant(tick: 1, hz: 60, epoch: epoch);
      final sampler = await OceanSamplerCpu.create(
        state: calmSea(),
        frame: frame,
        now: () => instant,
        coverage: coverage,
      );
      final bridge = OceanPhysicsBridge(
        world: world,
        sampler: sampler,
        policy: OceanQueryPolicy(),
        density: 1000,
      );
      try {
        final body = cube(world);
        bridge.bind(body, cubeShape());
        final snapshot = world.snapshot();
        coverage.available = false;
        await expectLater(bridge.prepare(instant), throwsArgumentError);
        expect(body.state.velocity, Vec3.zero);
        expect(bridge.lastFailure, isNotNull);
        coverage.available = true;
        bridge.apply(await bridge.prepare(instant), 1 / 60);
        world.step();
        world.restore(snapshot);
        instant = GeoInstant(tick: 0, hz: 60, epoch: epoch, generation: 1);
        bridge.beginReplay(instant);
        expect(bridge.bindingCount, 0);
        expect(() => bridge.bind(body, cubeShape()), throwsStateError);
        final restored = world.body(body.id);
        bridge.bind(restored, cubeShape());
        instant = instant.withTick(1);
        bridge.apply(await bridge.prepare(instant), 1 / 60);
        world.step();
        expect(restored.state.velocity.length, lessThan(1e-6));
      } finally {
        await bridge.close();
        await sampler.close();
        world.close();
      }
    },
  );
}
