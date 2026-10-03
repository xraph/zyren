import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'perception_test.dart' show Fixture;

void main() {
  test(
    'snapshot iterable admission stops before unbounded materialization',
    () {
      var read = 0;
      final entity = SensorEntity(
        handle: GameEntityHandle('observer', 1),
        pose: PhysicsPose(),
      );
      expect(
        () => SensorSnapshot(
          episodeId: 'ep',
          tick: 1,
          worldRevision: 1,
          entities: excessiveEntities(entity, () => read++),
          colliders: {},
          currentRevision: () => 1,
          geometryLoaded: (_, _) => true,
        ),
        throwsArgumentError,
      );
      expect(read, 16385);
    },
  );

  test(
    'hidden motion cannot consume the visible peer quota with a small ray budget',
    () {
      List<double> capture(Vec3 hidden) {
        final f = Fixture();
        try {
          f.entity('a-hidden', hidden);
          f.entity('b-visible', const Vec3(2, 0, -2));
          f.obstacle(
            const Vec3(-1, 0, -4),
            const Vec3(.3, 2, .1),
            material: SensorMaterial.glass,
          );
          f.obstacle(const Vec3(-1.5, 0, -6), const Vec3(.5, 2, .1));
          f.obstacle(const Vec3(0, 0, 4), const Vec3(2, 2, .1));
          f.world.step();
          final profile = SensorProfile(
            range: 10,
            queryBudget: 2,
            maxEntities: 2,
            materials: {SensorMaterial.glass: SensorMaterialRule.pass},
          );
          final registry = SensorRegistry()..register(VisionSensor(profile));
          final frame = ObservationAssembler(
            registry: registry,
            profile: profile,
          ).build(f.snapshot(), f.actor);
          expect(frame.visibleIds, ['b-visible']);
          return frame.tensor.float32Values;
        } finally {
          f.world.close();
        }
      }

      expect(capture(const Vec3(-2, 0, -8)), capture(const Vec3(0, 0, 8)));
    },
  );
  test(
    'inaudible hidden sound motion cannot consume an audible peer quota',
    () {
      List<double> capture(Vec3 hidden) {
        final f = Fixture();
        try {
          f.obstacle(
            const Vec3(-1, 0, -4),
            const Vec3(.3, 2, .1),
            material: SensorMaterial.glass,
          );
          f.obstacle(const Vec3(-1.5, 0, -6), const Vec3(.5, 2, .1));
          f.world.step();
          final snapshot = SensorSnapshot.fromPhysics(
            episodeId: 'ep',
            tick: 1,
            worldRevision: 1,
            world: f.world,
            bindings: f.bindings,
            colliders: f.colliders,
            currentRevision: () => 1,
            geometryLoaded: (_, _) => true,
            sounds: [
              SensorSoundSample(
                id: 'a-hidden',
                category: 'voice',
                tick: 1,
                position: hidden,
                loudness: 1,
                range: 30,
              ),
              SensorSoundSample(
                id: 'b-audible',
                category: 'voice',
                tick: 1,
                position: const Vec3(2, 0, -2),
                loudness: 1,
                range: 30,
              ),
            ],
          );
          final profile = SensorProfile(
            range: 10,
            queryBudget: 2,
            materials: {SensorMaterial.glass: SensorMaterialRule.pass},
          );
          final sensor = HearingSensor(
            profile,
            maxSounds: 2,
            obstructionGain: 0,
          );
          final registry = SensorRegistry()..register(sensor);
          final frame = ObservationAssembler(
            registry: registry,
            profile: profile,
          ).build(snapshot, f.actor);
          expect(frame.readings.single.sounds.length, 1);
          return frame.tensor.float32Values;
        } finally {
          f.world.close();
        }
      }

      expect(capture(const Vec3(-2, 0, -8)), capture(const Vec3(-2, 0, -20)));
    },
  );
}

Iterable<SensorEntity> excessiveEntities(
  SensorEntity entity,
  void Function() counted,
) sync* {
  while (true) {
    counted();
    yield entity;
  }
}
