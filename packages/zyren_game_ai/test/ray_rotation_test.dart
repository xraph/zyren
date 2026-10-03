import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';

void main() {
  test('rotated empty native rays stay within the declared range', () {
    final world = PhysicsWorld(gravity: Vec3.zero);
    addTearDown(world.close);
    final body = world.createBody(kind: BodyKind.fixed);
    final actor = GameEntityHandle('actor', 1);
    final profile = SensorProfile(
      range: 20,
      maxEntities: 1,
      maxCandidates: 1,
      queryBudget: 1,
    );
    final sensor = RaySensor(profile, directions: [const Vec3(0, 0, 1)]);
    final registry = SensorRegistry()..register(sensor);
    var crossed = false;
    for (var tick = 1; tick <= 200; tick++) {
      final rotation = Quat.axisAngle(const Vec3(0, 1, 0), tick * .07);
      crossed |= rotation.rotate(const Vec3(0, 0, 20)).length > 20;
      final snapshot = SensorSnapshot(
        episodeId: 'rotation',
        tick: tick,
        worldRevision: tick,
        world: world,
        entities: [
          SensorEntity(
            handle: actor,
            pose: PhysicsPose(rotation: rotation),
            body: body,
          ),
        ],
        colliders: {},
        currentRevision: () => tick,
        geometryLoaded: (_, _) => true,
      );
      final reading = registry.sample(sensor, snapshot, actor);
      expect(reading.values.single, lessThanOrEqualTo(20));
      expect(reading.validity.single, 1);
    }
    expect(
      crossed,
      isTrue,
      reason: 'The fixture reaches a rounding boundary without a sensor clamp.',
    );
  });
}
