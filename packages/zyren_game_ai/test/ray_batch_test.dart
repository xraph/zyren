import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'perception_test.dart' show Fixture;

const directions = [Vec3(0, 0, -1), Vec3(1, 0, 0), Vec3(-1, 0, 0)];

void main() {
  test(
    'batch retains scalar material classification, ordering and query quotas',
    () {
      for (final material in SensorMaterial.values.where(
        (m) => m != SensorMaterial.smoke,
      )) {
        final f = Fixture();
        try {
          f.obstacle(
            const Vec3(0, 0, -3),
            const Vec3(1, 1, .2),
            material: material,
          );
          f.world.step();
          for (final limit in [0, 1, 2, 3]) {
            final batch = RaySensor(
              SensorProfile(range: 10, queryBudget: limit),
              directions: directions,
            );
            // Smoke is absent, so permitting it selects the sequential path
            // without changing the meaning of any physical hit in this world.
            final scalar = RaySensor(
              SensorProfile(
                range: 10,
                queryBudget: limit,
                materials: {SensorMaterial.smoke: SensorMaterialRule.pass},
              ),
              directions: directions,
            );
            final a = batch.sample(f.snapshot(), f.actor);
            final b = scalar.sample(f.snapshot(), f.actor);
            expect(a.values, b.values);
            expect(a.validity, b.validity);
            expect(a.state, b.state);
            expect(batch.lastDiagnostics!.queriesUsed, limit);
            expect(
              batch.lastDiagnostics!.queriesUsed,
              scalar.lastDiagnostics!.queriesUsed,
            );
          }
        } finally {
          f.world.close();
        }
      }
    },
  );

  test('unloaded segments do not consume another ray budget slot', () {
    final f = Fixture();
    try {
      final base = f.snapshot();
      final snapshot = SensorSnapshot(
        episodeId: base.episodeId,
        tick: base.tick,
        worldRevision: base.worldRevision,
        entities: base.entities.values,
        colliders: base.colliders,
        world: f.world,
        currentRevision: () => f.revision,
        geometryLoaded: (_, to) => to.x != 0,
      );
      final sensor = RaySensor(
        SensorProfile(range: 10, queryBudget: 1),
        directions: directions,
      );
      final reading = sensor.sample(snapshot, f.actor);
      expect(reading.values, [0, 10, 0]);
      expect(reading.validity, [0, 1, 0]);
      expect(sensor.lastDiagnostics!.queriesUsed, 1);
    } finally {
      f.world.close();
    }
  });

  test('transparent traversal keeps its original sequential query budget', () {
    final f = Fixture();
    try {
      f.obstacle(
        const Vec3(0, 0, -3),
        const Vec3(1, 1, .2),
        material: SensorMaterial.glass,
      );
      f.obstacle(const Vec3(0, 0, -6), const Vec3(1, 1, .2));
      final sensor = RaySensor(
        SensorProfile(
          range: 10,
          queryBudget: 3,
          materials: {SensorMaterial.glass: SensorMaterialRule.pass},
        ),
        directions: directions,
      );
      final reading = sensor.sample(f.snapshot(), f.actor);
      expect(reading.values.first, closeTo(5.8, 1e-4));
      expect(reading.validity, [1, 0, 0]);
      expect(sensor.lastDiagnostics!.queriesUsed, 3);
    } finally {
      f.world.close();
    }
  });

  test('revision changes during geometry admission invalidate queued rays', () {
    final f = Fixture();
    try {
      final base = f.snapshot();
      final snapshot = SensorSnapshot(
        episodeId: base.episodeId,
        tick: base.tick,
        worldRevision: base.worldRevision,
        entities: base.entities.values,
        colliders: base.colliders,
        world: f.world,
        currentRevision: () => f.revision,
        geometryLoaded: (_, _) {
          f.revision++;
          return true;
        },
      );
      final sensor = RaySensor(
        SensorProfile(range: 10),
        directions: directions,
      );
      final reading = sensor.sample(snapshot, f.actor);
      expect(reading.validity, [0, 0, 0]);
      expect(reading.state, SensorState.unknown);
    } finally {
      f.world.close();
    }
  });

  test('missing and closed physics never become known empty space', () {
    final f = Fixture();
    try {
      final base = f.snapshot();
      final missing = SensorSnapshot(
        episodeId: base.episodeId,
        tick: base.tick,
        worldRevision: base.worldRevision,
        entities: base.entities.values,
        colliders: base.colliders,
        currentRevision: () => f.revision,
        geometryLoaded: (_, _) => true,
      );
      final sensor = RaySensor(
        SensorProfile(range: 10),
        directions: directions,
      );
      expect(sensor.sample(missing, f.actor).state, SensorState.unavailable);
      f.world.close();
      expect(sensor.sample(base, f.actor).state, SensorState.unavailable);
      expect(sensor.lastDiagnostics!.queriesUsed, 0);
    } finally {
      f.world.close();
    }
  });

  test(
    'actor exclusion, sensor exclusion and layer masks survive batching',
    () {
      final f = Fixture();
      try {
        final wall = f.world.createBody(
          kind: BodyKind.fixed,
          pose: PhysicsPose(position: const Vec3(0, 0, -3)),
        );
        final collider = wall.addCollider(const SphereShape(.5), membership: 2);
        f.colliders[collider.id] = const SensorCollider(SensorMaterial.opaque);
        f.world
            .createBody(
              kind: BodyKind.fixed,
              pose: PhysicsPose(position: const Vec3(0, 0, -1)),
            )
            .addCollider(const SphereShape(.5), sensor: true);
        final sensor = RaySensor(
          SensorProfile(range: 10, layerMask: 1),
          directions: directions,
        );
        final reading = sensor.sample(f.snapshot(), f.actor);
        expect(reading.values, [10, 10, 10]);
        expect(reading.validity, [1, 1, 1]);
        expect(sensor.lastDiagnostics!.queriesUsed, 3);
      } finally {
        f.world.close();
      }
    },
  );
}
