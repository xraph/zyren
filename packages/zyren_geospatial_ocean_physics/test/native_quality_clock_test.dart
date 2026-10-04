import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_geospatial_ocean_physics/zyren_geospatial_ocean_physics.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'support.dart';

final class _NativeIntegration extends GeoSimulationSystem {
  final PhysicsPlugin physics;
  _NativeIntegration(this.physics);
  @override
  String get id => 'physics.integrate';
  @override
  Set<String> get dependencies => {'ocean.buoyancy'};
  @override
  int get requiredHz => 60;
  @override
  void step(GeoInstant instant) => physics.advance(1 / 60);
}

void main() {
  test(
    'native water quality and presentation cadence preserve canonical buoyancy trajectories',
    () async {
      final state = OceanSeaState(
        seed: 42,
        canonicalResolution: 8,
        bands: [
          OceanWaveBand(
            patchMetres: 64,
            minWaveNumber: 0,
            maxWaveNumber: .5,
            windSpeed: 12,
            windHeadingRadians: .3,
            amplitude: .002,
            choppiness: .5,
          ),
        ],
      );
      final trajectories = <List<BodyState>>[];
      for (final renderHz in [30, 60, 120, 144]) {
        final backend = await NativeBackend.create();
        final scope = GpuScope.fromBackend(backend);
        final frame = worldFrame(),
            world = PhysicsWorld(gravity: const Vec3(0, 0, -9.81));
        var instant = GeoInstant(tick: 0, hz: 60, epoch: epoch), steps = 0;
        final sampler = await OceanSamplerCpu.create(
          state: state,
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
        final physics = PhysicsPlugin(
          world: world,
          externallyDriven: true,
          interpolate: false,
          beforeStep: (_) => steps++,
        );
        final scene = Scene(), object = Group();
        scene.add(object);
        physics.bind(object, body);
        final simulation = GeoSimulation(
          systems: [OceanBuoyancySystem(bridge), _NativeIntegration(physics)],
        );
        final driver = simulation.acquireDriver('native water quality fixture');
        final patch = OceanPatchId(face: 0, level: 16, x: 32768, y: 32768);
        final origin = patch.point(.5, .5);
        final geometry = OceanPatchGeometry(
          patch,
          origin,
          BufferGeometry(
            positions: [0, -8, -8, 0, 8, -8, 0, 8, 8, 0, -8, 8],
            normals: [1, 0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0],
            indices: [0, 1, 2, 0, 2, 3],
          ),
        );
        final camera = PerspectiveCamera(
          position: origin + const Vec3(15, 0, 0),
          target: origin,
          up: const Vec3(0, 0, 1),
          near: .1,
          far: 100,
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend.createView(),
          plugins: [physics],
        );
        final low = OceanRenderQuality.low.settings.copyWith(
          fftResolution: 4,
          maxBands: 1,
        );
        final high = low.copyWith(
          fftResolution: 8,
          ssrSteps: 32,
          sceneInputScale: .75,
        );
        OceanController<OceanWaterMaterial>? controller;
        Mesh? mesh;
        try {
          controller = await OceanController.create<OceanWaterMaterial>(
            scope,
            state: state,
            chartIds: [0],
            capabilities: backend.capabilities,
            quality: low,
            transitionDuration: const Duration(milliseconds: 100),
            plan: (quality, previous) => OceanQualityPlan(
              views: [
                OceanViewAllocation(
                  id: 'water',
                  size: PhysicalSize(24, 24),
                  geometryBytes: geometry.geometry.capture().gpuByteLength,
                  materialBytes: 1104,
                ),
              ],
              build: (context, waves) async {
                final water = await OceanWaterMaterial.create(
                  context.gpu,
                  waves: waves,
                  patch: patch,
                  geometrySpacingMetres: 1,
                  reflections: quality.reflections,
                );
                context.onClose(water.close);
                return water;
              },
            ),
          );
          final points = <BodyState>[];
          var publication = -1, transitions = 0;
          var visibleFrames = 0;
          for (var frameIndex = 1; frameIndex <= renderHz * 2; frameIndex++) {
            final due = frameIndex * 60 ~/ renderHz;
            while (steps < due) {
              instant = instant.withTick(instant.tick + 1);
              await driver.step(instant);
              points.add(body.state);
            }
            final before = body.state, completedSteps = world.completedSteps;
            if (renderHz != 30 &&
                (frameIndex == renderHz ~/ 2 ||
                    frameIndex == renderHz * 3 ~/ 2)) {
              await controller.setQuality(transitions++ == 0 ? high : low);
            }
            final elapsed = Duration(
              microseconds: (frameIndex * 1e6 / renderHz).round(),
            );
            await controller.advance(
              seconds: instant.seconds,
              elapsed: elapsed,
            );
            if (publication != controller.publicationRevision) {
              if (mesh != null) scene.remove(mesh);
              mesh = scene.add(controller.resources.createMesh(geometry));
              publication = controller.publicationRevision;
            }
            scene.renderSettings = controller.effectiveQuality.applyTo(
              scene.renderSettings,
            );
            mesh!.visible = frameIndex.isEven;
            final result =
                await engine.renderFrame(
                      elapsed: elapsed,
                      width: 24,
                      height: 24,
                    )
                    as ReadbackOutput;
            if (mesh.visible) {
              expect(
                result.image.pixels[(12 * 24 + 12) * 4 + 2],
                greaterThan(5),
              );
              visibleFrames++;
            }
            expect(world.completedSteps, completedSteps);
            expect(body.state.pose.position, before.pose.position);
            expect(body.state.pose.rotation, before.pose.rotation);
            expect(body.state.velocity, before.velocity);
            expect(body.state.angularVelocity, before.angularVelocity);
            expect(controller.seaStateRevision, sampler.state.revision);
          }
          expect(steps, 120);
          expect(instant.tick, 120);
          expect(visibleFrames, renderHz);
          expect(transitions, renderHz == 30 ? 0 : 2);
          trajectories.add(points);
        } finally {
          if (mesh != null) scene.remove(mesh);
          await engine.dispose();
          await controller?.close();
          physics.clearBindings();
          driver.dispose();
          await driver.whenClosed;
          await bridge.close();
          await sampler.close();
          world.close();
          await scope.close();
          expect((await backend.resourceStats()).liveAllocations, 0);
          await backend.close();
        }
      }
      var maximumPosition = 0.0, maximumVelocity = 0.0;
      for (final trajectory in trajectories.skip(1)) {
        for (var i = 0; i < trajectory.length; i++) {
          maximumPosition = math.max(
            maximumPosition,
            trajectory[i].pose.position.distanceTo(
              trajectories.first[i].pose.position,
            ),
          );
          maximumVelocity = math.max(
            maximumVelocity,
            trajectory[i].velocity.distanceTo(trajectories.first[i].velocity),
          );
          expect(
            trajectory[i].pose.rotation,
            trajectories.first[i].pose.rotation,
          );
          expect(
            trajectory[i].angularVelocity,
            trajectories.first[i].angularVelocity,
          );
        }
      }
      expect(maximumPosition, lessThan(1e-7));
      expect(maximumVelocity, lessThan(1e-7));
      print(
        'Native 60 Hz buoyancy at 30/60/120/144 Hz presentation: max position delta $maximumPosition m, velocity delta $maximumVelocity m/s.',
      );
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
    timeout: const Timeout(Duration(minutes: 4)),
  );
}
