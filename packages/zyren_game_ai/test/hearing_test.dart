import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'perception_test.dart' show Fixture;

void main() {
  test(
    'audible hidden event exposes uncertainty but no exact hidden source identity or coordinates',
    () {
      List<double> hear(Vec3 position) {
        final f = Fixture();
        try {
          f.obstacle(const Vec3(0, 0, -4), const Vec3(3, 2, .1));
          f.world.step();
          final event = GameSoundEvent(
            id: 'sound',
            category: 'footstep',
            tick: 1,
            position: position,
            sourceEntityId: 'hidden',
            loudness: 1,
            range: 20,
          );
          final snapshot = SensorSnapshot.fromPhysics(
            episodeId: 'episode',
            tick: 2,
            worldRevision: 1,
            world: f.world,
            bindings: f.bindings,
            colliders: f.colliders,
            currentRevision: () => 1,
            geometryLoaded: (_, _) => true,
            sounds: [SensorSoundSample.fromEvent(event)],
          );
          final sensor = HearingSensor(SensorProfile(range: 10), maxSounds: 1);
          final reading = sensor.sample(snapshot, f.actor);
          expect(reading.provenance, SensorProvenance.audible);
          expect(reading.entities, isEmpty);
          expect(reading.validity, everyElement(1));
          expect(reading.sounds.single.obstructed, isTrue);
          expect(
            reading.sounds.single.bearingUncertaintyRadians,
            greaterThan(0),
          );
          expect(
            reading.sounds.single.distanceUpperMetres -
                reading.sounds.single.distanceLowerMetres,
            2.5,
          );
          return reading.values;
        } finally {
          f.world.close();
        }
      }

      expect(hear(const Vec3(.2, 0, -6)), hear(const Vec3(.4, 0, -6.5)));
    },
  );
  test(
    'visible, audible and last-seen observations retain distinct provenance and age',
    () {
      final f = Fixture();
      try {
        final target = f.entity('target', const Vec3(0, 0, -2));
        f.world.step();
        final visible = f.frame();
        expect(visible.readings.single.provenance, SensorProvenance.visible);
        final memory = LastSeenSensor(SensorProfile(range: 10, maxEntities: 2));
        memory.remember(visible);
        target.teleport(PhysicsPose(position: const Vec3(0, 0, -8)));
        f.obstacle(const Vec3(0, 0, -4), const Vec3(3, 2, .1));
        f.world.step();
        final snapshot = SensorSnapshot.fromPhysics(
          episodeId: 'episode',
          tick: 5,
          worldRevision: 1,
          world: f.world,
          bindings: f.bindings,
          colliders: f.colliders,
          currentRevision: () => 1,
          geometryLoaded: (_, _) => true,
          sounds: [
            SensorSoundSample(
              id: 'event',
              category: 'voice',
              tick: 4,
              position: const Vec3(0, 0, -8),
              loudness: 1,
              range: 30,
            ),
          ],
        );
        expect(
          VisionSensor(
            SensorProfile(range: 10),
          ).sample(snapshot, f.actor).entities,
          isEmpty,
        );
        final heard = HearingSensor(
          SensorProfile(range: 10),
        ).sample(snapshot, f.actor);
        expect(heard.provenance, SensorProvenance.audible);
        expect(heard.sounds.single.eventTick, 4);
        final remembered = memory.sample(snapshot, f.actor);
        expect(remembered.provenance, SensorProvenance.lastSeen);
        expect(remembered.entities.single.localPosition, const Vec3(0, 0, -2));
        expect(remembered.entities.single.tick, 1);
        expect(
          remembered.entities.single.handle,
          GameEntityHandle('target', 1),
        );
      } finally {
        f.world.close();
      }
    },
  );
  test(
    'unloaded obstruction and hearing budget cannot be treated as an audible clear path',
    () {
      final f = Fixture();
      try {
        f.world.step();
        SensorSnapshot snapshot(bool loaded) => SensorSnapshot.fromPhysics(
          episodeId: 'ep',
          tick: 1,
          worldRevision: 1,
          world: f.world,
          bindings: f.bindings,
          colliders: f.colliders,
          currentRevision: () => 1,
          geometryLoaded: (_, _) => loaded,
          sounds: [
            SensorSoundSample(
              id: 'event',
              category: 'voice',
              tick: 1,
              position: const Vec3(0, 0, -2),
              loudness: 1,
              range: 20,
            ),
          ],
        );
        final missing = HearingSensor(
          SensorProfile(range: 10),
        ).sample(snapshot(false), f.actor);
        expect(missing.state, SensorState.unknown);
        expect(missing.sounds, isEmpty);
        final exhausted = HearingSensor(
          SensorProfile(range: 10, queryBudget: 0),
        ).sample(snapshot(true), f.actor);
        expect(exhausted.state, SensorState.unknown);
        expect(exhausted.validity, everyElement(0));
      } finally {
        f.world.close();
      }
    },
  );
}
