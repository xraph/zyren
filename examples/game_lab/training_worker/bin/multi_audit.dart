import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/multi_agent_scenario.dart';

Future<void> main() async {
  final rows = <Map<String, Object?>>[];
  for (final split in [TrainingSplit.training, TrainingSplit.validation]) {
    for (final competitive in [false, true]) {
      final scenario = multiAgentScenario(
        competitive: competitive,
        split: split,
        heldOut: split == TrainingSplit.validation,
      );
      final env = GameTrainingEnvironment(
        runId: 'train-dev-audit',
        environmentId: 'train-dev-audit',
        scenarios: {scenario.id: scenario},
        purpose: split,
      );
      try {
        for (final seed in [7, 17, 29]) {
          for (final mode in [
            'stationary',
            'teacher',
            if (competitive) ...['pursuer-only', 'evader-only'],
          ]) {
            var result = await env.reset(seed: seed, scenario: scenario.id);
            var steps = 0;
            while (!result.terminated &&
                !result.truncated &&
                steps < scenario.maxSteps) {
              final teacher =
                  (result.info['training_only'] as Map)['teacher_actions']
                      as Map;
              result = await env.step({
                for (final actor in result.observations.keys)
                  actor: Float32List.fromList(
                    mode == 'teacher' ||
                            mode == 'pursuer-only' && actor == 'a' ||
                            mode == 'evader-only' && actor == 'b'
                        ? (teacher[actor] as List).cast<double>()
                        : [2, 2, 2, 1, 0, 0],
                  ),
              });
              steps++;
            }
            rows.add({
              'task': scenario.id,
              'split': split.name,
              'seed': seed,
              'mode': mode,
              'steps': steps,
              'results': result.info['per_agent_results'],
              'legal': result.info['legal_arena'],
              'collision': result.info['collision'],
              'physics_backend': result.info['physics_backend'],
              'observation_schema_hash': result.info['observation_schema_hash'],
              'action_schema_hash': result.info['action_schema_hash'],
              'multi_profile': result.info['multi_profile'],
              'messages': result.info['team_messages_delivered'],
              'distances': (result.info['training_only'] as Map)['distances'],
              'scenario_spec': result.info['scenario_spec'],
            });
          }
        }
      } finally {
        await env.close();
      }
    }
  }
  stdout.writeln(
    jsonEncode({'scope': 'TRAIN-dev feasibility only', 'rows': rows}),
  );
}
