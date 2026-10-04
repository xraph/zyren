import 'package:zyren_game_lab_training_worker/multi_agent_scenario.dart';
import 'package:zyren_game_lab_training_worker/worker_transport.dart';
import 'package:zyren_game/training.dart';
import 'dart:convert';
import 'dart:io';

Map<String, GameTrainingScenario> catalog() => {
  ...multiAgentScenarioCatalog(),
  ...multiAgentScenarioCatalog(validation: true),
  ...multiAgentScenarioCatalog(evaluation: true),
};
Future<void> main(List<String> args) async {
  if (args.contains('--scenario-specs') ||
      args.contains('--evaluation-specs') ||
      args.contains('--validation-specs')) {
    final evaluation = args.contains('--evaluation-specs'),
        validation = args.contains('--validation-specs');
    final scenarios = multiAgentScenarioCatalog(
      evaluation: evaluation,
      validation: validation,
    );
    final env = GameTrainingEnvironment(
      runId: 'multi-specs',
      environmentId: 'multi-specs',
      purpose: evaluation
          ? TrainingSplit.test
          : validation
          ? TrainingSplit.validation
          : TrainingSplit.training,
      scenarios: scenarios,
    );
    try {
      final specs = <Object?>[];
      for (final id in scenarios.keys) {
        specs.add(
          (await env.reset(seed: 7, scenario: id)).info['scenario_spec'],
        );
      }
      stdout.writeln(jsonEncode(specs));
    } finally {
      await env.close();
    }
  } else {
    await runTrainingProtocol(
      catalog,
      capabilities: const {'structured', 'native-physics', 'multi-agent'},
    );
  }
}
