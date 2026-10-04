import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'runtime_native_test.dart' show RuntimeFixture;

void main() {
  test(
    'hybrid unknown input clears staged requests and admits fresh recovery',
    () async {
      final f = RuntimeFixture(brain: 'hybrid');
      try {
        await f.start();
        final policy = f.ai.group!.brainFor(f.npc)!;
        expect(policy.hasPending, isTrue);
        final body = f.runtime.resolveBody(f.npc)!;
        body.teleport(PhysicsPose(position: const Vec3(100, 1.5, 0)));
        for (var i = 0; i < 100; i++) {
          await f.step();
          if (f.ai
                  .observation(f.npc)!
                  .readings
                  .firstWhere((r) => r.sensorId == 'body')
                  .state ==
              SensorState.unknown) {
            break;
          }
        }
        expect(
          f.ai
              .observation(f.npc)!
              .readings
              .firstWhere((r) => r.sensorId == 'body')
              .state,
          SensorState.unknown,
        );
        expect(policy.hasPending, isFalse);
        await f.step();
        expect(policy.hasPending, isFalse);
        body.teleport(PhysicsPose(position: const Vec3(0, 1.5, 0)));
        for (var i = 0; i < 20; i++) {
          await f.step();
          if (f.ai
                  .observation(f.npc)!
                  .readings
                  .firstWhere((r) => r.sensorId == 'body')
                  .state ==
              SensorState.known) {
            break;
          }
        }
        expect(
          f.ai
              .observation(f.npc)!
              .readings
              .firstWhere((r) => r.sensorId == 'body')
              .state,
          SensorState.known,
        );
        expect(policy.hasPending, isTrue);
        await f.step();
        expect(f.ai.completedDecisions, greaterThan(0));
      } finally {
        await f.close();
      }
    },
  );
}
