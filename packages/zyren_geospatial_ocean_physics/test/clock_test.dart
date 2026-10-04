import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean_physics/zyren_geospatial_ocean_physics.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support.dart';

/// Exercises real presentation callbacks; pixel rendering is not GPU qualification.
final class PresentationFixture implements SceneRenderer {
  @override
  final capabilities = RendererCapabilities(
    name: 'ocean clock fixture',
    features: {},
    maxDimension: 8,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}

final class NativeIntegration extends GeoSimulationSystem {
  final PhysicsPlugin physics;
  NativeIntegration(this.physics);
  @override
  String get id => 'physics.integrate';
  @override
  Set<String> get dependencies => const {'ocean.buoyancy'};
  @override
  int get requiredHz => 60;
  @override
  void step(GeoInstant instant) => physics.advance(1 / 60);
}

void main() {
  test(
    '60 Hz native trajectories survive 30, 60, 120 and 144 Hz presentation and visual hide',
    () async {
      final trajectories = <List<Vec3>>[];
      for (final renderHz in [30, 60, 120, 144]) {
        final frame = worldFrame(),
            world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81));
        var instant = GeoInstant(tick: 0, hz: 60, epoch: epoch), steps = 0;
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
        final body = cube(world, position: const Vec3(0, 0, .3));
        bridge.bind(
          body,
          cubeShape(),
          solver: BuoyancySolver(
            drag: BuoyancyDrag(linear: 1000, angular: 1000),
          ),
        );
        final scene = Scene(), object = Group();
        scene.add(object);
        final physics = PhysicsPlugin(
          world: world,
          externallyDriven: true,
          interpolate: false,
          beforeStep: (_) => steps++,
        );
        physics.bind(object, body);
        final simulation = GeoSimulation(
          systems: [OceanBuoyancySystem(bridge), NativeIntegration(physics)],
        );
        final driver = simulation.acquireDriver('ocean clock fixture');
        final engine = await SceneEngine.create(
          scene: scene,
          camera: PerspectiveCamera(),
          rendererFactory: () async => PresentationFixture(),
          plugins: [physics],
        );
        try {
          final points = <Vec3>[];
          for (var frameIndex = 1; frameIndex <= renderHz * 2; frameIndex++) {
            final due = frameIndex * 60 ~/ renderHz;
            while (steps < due) {
              instant = instant.withTick(instant.tick + 1);
              await driver.step(instant);
              points.add(body.state.pose.position);
            }
            object.visible = frameIndex % 2 == 0;
            final before = body.state;
            await engine.render(
              elapsed: Duration(
                microseconds: (frameIndex * 1e6 / renderHz).round(),
              ),
              width: 8,
              height: 8,
            );
            expect(body.state.pose.position, before.pose.position);
            expect(body.state.velocity, before.velocity);
          }
          expect(steps, 120);
          expect(instant.tick, 120);
          trajectories.add(points);
        } finally {
          await engine.dispose();
          physics.clearBindings();
          driver.dispose();
          await driver.whenClosed;
          await bridge.close();
          await sampler.close();
          world.close();
        }
      }
      for (final points in trajectories.skip(1)) {
        for (var i = 0; i < points.length; i++) {
          expect(points[i].distanceTo(trajectories.first[i]), lessThan(1e-7));
        }
      }
    },
  );
}
