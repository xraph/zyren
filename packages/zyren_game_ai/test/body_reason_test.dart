import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test(
    'unknown body readings preserve masks and explain every missing input',
    () {
      final actor = GameEntityHandle('observer', 1);
      SensorReading sample(double speed, bool? grounded) =>
          BodySensor(maxSpeed: 10).sample(
            SensorSnapshot(
              episodeId: 'ep',
              tick: 1,
              worldRevision: 1,
              entities: [
                SensorEntity(
                  handle: actor,
                  pose: PhysicsPose(),
                  velocity: Vec3(speed, 0, 0),
                  grounded: grounded,
                ),
              ],
              colliders: const {},
              currentRevision: () => 1,
              geometryLoaded: (_, _) => true,
            ),
            actor,
          );
      expect(sample(5, true).reason, isNull);
      final speed = sample(11, true);
      expect(speed.state, SensorState.unknown);
      expect(speed.reason, 'speed-out-of-range');
      expect(speed.validity, [0, 0, 0, 1]);
      expect(sample(5, null).reason, 'grounding-unavailable');
      expect(
        sample(11, null).reason,
        'speed-out-of-range,grounding-unavailable',
      );
      expect(sample(11, null).validity, [0, 0, 0, 0]);
    },
  );
}
