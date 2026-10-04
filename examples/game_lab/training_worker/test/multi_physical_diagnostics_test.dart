import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/multi_agent_scenario.dart';

void main() {
  test(
    'native flat-capsule diagnostics include terminal post-step XYZ',
    () async {
      final scenario = multiAgentScenario(competitive: true);
      final env = GameTrainingEnvironment(
        runId: 'physics-diagnostics',
        environmentId: 'physics-diagnostics',
        scenarios: {scenario.id: scenario},
      );
      try {
        var result = await env.reset(seed: 7, scenario: scenario.id);
        for (var index = 0; index <= 400; index++) {
          final central = result.info['training_only'] as Map;
          final physical = central['physical_diagnostics'] as Map;
          expect(physical['tick'], result.info['tick']);
          expect(physical['positions'], central['state']);
          expect(physical['actor_ids'], ['a', 'b']);
          expect(
            physical['actor_generations'],
            result.info['actor_generations'],
          );
          expect(physical['contact_depths'], isNull);
          expect(physical['collision'], isFalse);
          expect(physical['terminal'], index == 400);
          final positions = (physical['positions'] as List).cast<double>();
          final clearances = physical['floor_clearance'] as Map;
          for (var actor = 0; actor < 2; actor++) {
            final id = actor == 0 ? 'a' : 'b';
            expect(
              clearances[id],
              closeTo(positions[actor * 3 + 1] - .8, 1e-6),
            );
            expect(clearances[id], greaterThanOrEqualTo(-.001));
            expect(result.observations[id]!.length, 36);
          }
          expect(
            (result.info['observation_schema'] as Map)['fields'],
            everyElement(isNot(containsPair('id', 'physical_diagnostics'))),
          );
          if (index == 400) break;
          result = await env.step({
            for (final id in ['a', 'b'])
              id: Float32List.fromList([2, 2, 2, 1, 0, 0]),
          });
        }
      } finally {
        await env.close();
      }
    },
  );
}
