import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/multi_agent_scenario.dart';

void main() {
  test(
    'competitive timeout awards only the bounded surviving evader',
    () async {
      final scenario = multiAgentScenario(competitive: true);
      final env = GameTrainingEnvironment(
        runId: 'multi-task',
        environmentId: 'multi-task',
        scenarios: {scenario.id: scenario},
      );
      try {
        var result = await env.reset(seed: 7, scenario: scenario.id);
        for (var tick = 0; tick < scenario.maxSteps; tick++) {
          result = await env.step({
            for (final actor in result.observations.keys)
              actor: Float32List.fromList([2, 2, 2, 1, 0, 0]),
          });
        }
        expect(result.info['per_agent_results'], {'a': 'loss', 'b': 'win'});
        expect(result.info['legal_arena'], isTrue);
        expect(result.info['task_capture'], isFalse);
        expect(result.info['success'], isFalse);
      } finally {
        await env.close();
      }
    },
  );
  test(
    'native capture gives only the pursuer credit and excludes floor contact',
    () async {
      final scenario = multiAgentScenario(competitive: true);
      final env = GameTrainingEnvironment(
        runId: 'capture',
        environmentId: 'capture',
        scenarios: {scenario.id: scenario},
      );
      try {
        var result = await env.reset(seed: 17, scenario: scenario.id);
        for (
          var step = 0;
          step < scenario.maxSteps && !result.terminated;
          step++
        ) {
          final teacher =
              (result.info['training_only'] as Map)['teacher_actions'] as Map;
          result = await env.step({
            'a': Float32List.fromList((teacher['a'] as List).cast<double>()),
            'b': Float32List.fromList([2, 2, 2, 1, 0, 0]),
          });
        }
        expect(result.info['task_capture'], isTrue);
        expect(result.info['per_agent_results'], {'a': 'win', 'b': 'loss'});
        expect(result.info['collision'], isFalse);
      } finally {
        await env.close();
      }
    },
  );
}
