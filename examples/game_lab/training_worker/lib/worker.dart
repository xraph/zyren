import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:zyren_game/training.dart';
import 'native_scenario.dart';
import 'policy_probe.dart';
import 'task_scenarios.dart';
import 'visual_scenario.dart';
import 'multi_agent_scenario.dart';
import 'worker_transport.dart';

Future<void> runTrainingWorker(List<String> args) async {
  if (args.length == 2 && args.first == '--policy-sequence') {
    await runPolicySequence(args[1]);
    return;
  }
  if (args.any(
    (arg) => [
      '--multi-scenario-specs',
      '--multi-evaluation-specs',
      '--multi-validation-specs',
    ].contains(arg),
  )) {
    final evaluation = args.contains('--multi-evaluation-specs'),
        validation = args.contains('--multi-validation-specs');
    final catalog = multiAgentScenarioCatalog(
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
      scenarios: catalog,
    );
    try {
      final specs = <Object?>[];
      for (final id in catalog.keys) {
        specs.add(
          (await env.reset(seed: 7, scenario: id)).info['scenario_spec'],
        );
      }
      stdout.writeln(jsonEncode(specs));
    } finally {
      await env.close();
    }
    return;
  }
  if (args.contains('--scenario-specs') ||
      args.contains('--evaluation-specs')) {
    final evaluation = args.contains('--evaluation-specs');
    final catalog = evaluation
        ? evaluationScenarioCatalog()
        : taskScenarioCatalog();
    final env = GameTrainingEnvironment(
      runId: 'scenario-specs',
      environmentId: 'scenario-specs',
      purpose: evaluation ? TrainingSplit.test : TrainingSplit.training,
      scenarios: catalog,
    );
    try {
      final specs = <Object?>[];
      for (final id in catalog.keys) {
        specs.add(
          (await env.reset(seed: 7, scenario: id)).info['scenario_spec'],
        );
      }
      stdout.writeln(jsonEncode(specs));
    } finally {
      await env.close();
    }
    return;
  }

  if (args.contains('--fixture-log')) {
    final env = GameTrainingEnvironment(
      runId: 'reference',
      environmentId: 'reference',
      scenarios: {'native-body': nativeBodyScenario()},
    );
    try {
      await env.reset(seed: 7, scenario: 'native-body');
      final log = <Map<String, Object?>>[];
      for (var i = 0; i < 1000; i++) {
        final result = await env.step({
          'actor': Float32List.fromList([0.25, -0.5]),
        });
        log.add({
          'tick': result.info['tick'],
          'action': result.info['accepted_action'],
          'position': result.info['physics_position'],
        });
      }
      stdout.writeln(jsonEncode(log));
    } finally {
      await env.close();
    }
    return;
  }
  await runTrainingProtocol(trainingWorkerCatalog);
}

Map<String, GameTrainingScenario> trainingWorkerCatalog() => {
  'native-body': nativeBodyScenario(),
  ...taskScenarioCatalog(),
  ...evaluationScenarioCatalog(),
  ...visualScenarioCatalog(),
  ...visualScenarioCatalog(evaluation: true),
  ...visualScenarioCatalog(validation: true),
  ...multiAgentScenarioCatalog(),
  ...multiAgentScenarioCatalog(evaluation: true),
  ...multiAgentScenarioCatalog(validation: true),
};
