import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean_physics/zyren_geospatial_ocean_physics.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support.dart';

void main() {
  test('combined current error respects the stricter bridge policy', () async {
    final world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81));
    final frame = worldFrame();
    final instant = GeoInstant(tick: 1, hz: 60, epoch: epoch);
    final current = FixtureCurrent()
      ..velocity = frame.vectorToEcef(const Vec3(2, 0, 0))
      ..error = .01;
    final sampler = await OceanSamplerCpu.create(
      state: calmSea(),
      frame: frame,
      now: () => instant,
      coverage: const OceanAllWaterCoverage(),
    );
    final bridge = OceanPhysicsBridge(
      world: world,
      sampler: sampler,
      current: current,
      policy: OceanQueryPolicy(maxVelocityErrorMetresPerSecond: .001),
    );
    try {
      final body = cube(world);
      bridge.bind(body, cubeShape());
      await expectLater(bridge.prepare(instant), throwsStateError);
      expect(world.completedSteps, 0);
      expect(body.state.velocity, Vec3.zero);
      current
        ..error = .0005
        ..revision = 'two';
      final batch = await bridge.prepare(instant);
      expect(batch.bodies, hasLength(1));
      expect(bridge.lastFailure, isNull);
      bridge.apply(batch, world.fixedStep);
      world.step();
      expect(world.completedSteps, 1);
    } finally {
      await bridge.close();
      await sampler.close();
      world.close();
    }
  });
}
