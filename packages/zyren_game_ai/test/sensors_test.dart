import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'perception_test.dart' show Fixture;

void main() {
  test(
    'rays and local grids use real physical hits and keep missing cells invalid',
    () {
      final f = Fixture();
      try {
        f.obstacle(const Vec3(0, 0, -3), const Vec3(1, 1, .2));
        f.world.step();
        final profile = SensorProfile(range: 10);
        final rays = RaySensor(
          profile,
          directions: [const Vec3(0, 0, -1), const Vec3(1, 0, 0)],
        );
        final ray = rays.sample(f.snapshot(), f.actor);
        expect(ray.values.first, closeTo(2.8, 1e-4));
        expect(ray.values.last, 10);
        final grid = GridSensor(
          profile,
          centers: [const Vec3(0, 0, -3), const Vec3(3, 0, 0)],
        );
        expect(grid.sample(f.snapshot(), f.actor).values, [1, 0]);
        f.loaded = false;
        expect(rays.sample(f.snapshot(), f.actor).validity, [0, 0]);
        expect(grid.sample(f.snapshot(), f.actor).validity, [0, 0]);
      } finally {
        f.world.close();
      }
    },
  );
  test(
    'controller body state and affordances do not fill missing data with known zeros',
    () {
      final f = Fixture();
      try {
        f.world.step();
        final actor = f.snapshot().entities[f.actor]!;
        final snapshot = SensorSnapshot(
          episodeId: 'ep',
          tick: 1,
          worldRevision: 1,
          entities: [
            SensorEntity(
              handle: f.actor,
              pose: actor.pose,
              velocity: const Vec3(2, 0, 0),
              grounded: true,
              affordances: [.5, 1],
            ),
          ],
          colliders: f.colliders,
          world: f.world,
          currentRevision: () => 1,
          geometryLoaded: (_, _) => true,
        );
        expect(BodySensor().sample(snapshot, f.actor).values, [2, 0, 0, 1]);
        expect(BodySensor().sample(f.snapshot(), f.actor).validity.last, 0);
        final sensor = AffordanceSensor(actions: ['use', 'jump']);
        expect(sensor.sample(snapshot, f.actor).values, [.5, 1]);
        expect(sensor.sample(f.snapshot(), f.actor).state, SensorState.unknown);
      } finally {
        f.world.close();
      }
    },
  );
  test(
    'cadence is schema pinned and diagnostics expose actual query counts',
    () {
      final f = Fixture();
      try {
        f.entity('visible', const Vec3(0, 0, -2));
        f.world.step();
        final registry = SensorRegistry();
        final sensor = VisionSensor(SensorProfile(range: 10, cadenceTicks: 2));
        registry.register(sensor);
        expect(() => registry.register(sensor), throwsStateError);
        final skipped = registry.sample(sensor, f.snapshot(), f.actor);
        expect(skipped.validity, everyElement(0));
        final snapshot = SensorSnapshot.fromPhysics(
          episodeId: 'ep',
          tick: 2,
          worldRevision: 1,
          world: f.world,
          bindings: f.bindings,
          colliders: f.colliders,
          currentRevision: () => 1,
          geometryLoaded: (_, _) => true,
        );
        expect(
          registry.sample(sensor, snapshot, f.actor).entities.single.handle.id,
          'visible',
        );
        expect(registry.diagnostics.single.queriesUsed, 1);
        expect(registry.diagnostics.single.candidatesConsidered, 1);
      } finally {
        f.world.close();
      }
    },
  );
  test(
    'schema changes when material, hearing uncertainty or ray directions change',
    () {
      final profile = SensorProfile();
      ObservationAssembler assembly(GameSensor s) {
        final r = SensorRegistry()..register(s);
        return ObservationAssembler(registry: r, profile: profile);
      }

      expect(
        assembly(VisionSensor(profile)).spec.hash,
        isNot(
          assembly(
            VisionSensor(
              SensorProfile(
                materials: {SensorMaterial.glass: SensorMaterialRule.pass},
              ),
            ),
          ).spec.hash,
        ),
      );
      expect(
        assembly(HearingSensor(profile, bearingSectors: 8)).spec.hash,
        isNot(assembly(HearingSensor(profile, bearingSectors: 16)).spec.hash),
      );
      expect(
        assembly(
          RaySensor(profile, directions: [const Vec3(0, 0, -1)]),
        ).spec.hash,
        isNot(
          assembly(
            RaySensor(profile, directions: [const Vec3(1, 0, 0)]),
          ).spec.hash,
        ),
      );
    },
  );
}
