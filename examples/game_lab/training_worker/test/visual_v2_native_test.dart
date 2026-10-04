import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/task_scenarios.dart';
import 'package:zyren_game_lab_training_worker/visual_v2_scenario.dart';

void main() {
  final enabled = Platform.environment['RUN_NATIVE_GPU'] == '1';
  test(
    'actual A6 TRAIN oracle admits copied pose and completes shared native guard course',
    () async {
      final scenario = visualV2GuardScenario();
      final env = GameTrainingEnvironment(
        runId: 'v2-feasibility',
        environmentId: 'v2-feasibility',
        scenarios: {scenario.id: scenario},
      );
      late TrainingTaskView owned;
      Map<String, Object?>? cleanup;
      final audited = visualV2GuardScenario(
        onPrepared: (v) => owned = v,
        onCleanup: (v) => cleanup = v,
      );
      final actual = GameTrainingEnvironment(
        runId: 'v2',
        environmentId: 'v2',
        scenarios: {audited.id: audited},
      );
      var captures = 0, contacts = 0, admitted = 0, steps = 0;
      final states = <String, int>{}, phase = <Map<String, Object?>>[];
      try {
        var result = await actual.reset(seed: 7, scenario: audited.id);
        expect(result.observations['actor']!.length, 35290);
        expect(result.info['oracle_visible'], true);
        expect(result.info['camera_cpu_readback_ns'], greaterThan(0));
        expect(result.info['activation_allowed'], false);
        expect(result.info['observation_width'], 35290);
        expect(result.info['delay_ticks'], 2);
        expect(result.info['baseline_action'], hasLength(74));
        expect(result.info['legality'], isEmpty);
        expect(result.info['execution_legality'], isEmpty);
        expect(result.info['reward_terms'], {'task.progress': 0.0});
        for (var i = 0; i < 600; i++) {
          result = await actual.step({
            'actor': Float32List.fromList(
              (result.info['teacher_estimate'] as List).cast<double>(),
            ),
          });
          steps++;
          contacts += result.info['collision'] == true ? 1 : 0;
          final state = (result.info['motion_state'] ?? 'none') as String;
          states[state] = (states[state] ?? 0) + 1;
          captures = result.info['camera_captures'] as int;
          if (result.info['goal_observed_tick'] != null) admitted++;
          if (i < 30 || i % 25 == 0 || result.info['success'] == true) {
            phase.add({
              'tick': result.info['tick'],
              'position': result.info['physics_position'],
              'state': state,
              'action': result.info['accepted_action'],
              'route': result.info['route_diagnostic'],
              'cameraYaw': result.info['camera_mount_yaw'],
              'visible': result.info['oracle_visible'],
              'sigma': result.info['goal_sigma'],
            });
          }
          if (result.info['success'] == true ||
              result.terminated ||
              result.truncated) {
            break;
          }
        }
        final receipt = {
          'schemaVersion': 2,
          'kind': 'TRAIN-native-deterministic-feasibility',
          'learned': false,
          'accepted': false,
          'steps': steps,
          'captures': captures,
          'contacts': contacts,
          'admittedTicks': admitted,
          'states': states,
          'phase': phase,
          'success': result.info['success'],
          'mapHash': result.info['map_hash'],
          'controllerHash': result.info['controller_configuration_hash'],
          'observationHash': result.info['observation_schema_hash'],
          'actionHash': result.info['action_schema_hash'],
        };
        final path = Platform.environment['VISUAL_V2_FEASIBILITY_RECEIPT'];
        if (path != null) {
          File(path).writeAsStringSync('${jsonEncode(receipt)}\n');
        }
        stdout.writeln(jsonEncode(receipt));
        expect(captures, greaterThan(1));
        expect(admitted, greaterThan(0));
        expect(result.info['success'], true);
        expect(contacts, 0);
      } finally {
        await actual.close();
        await env.close();
        expect(cleanup, {
          'cameraClosed': true,
          'pendingCaptures': 0,
          'reservedCaptureBytes': 0,
          'worldClosed': true,
          'actorAlive': false,
        });
      }
      expect(owned.simulation.world.isClosed, true);
      expect(owned.body.isAlive, false);
    },
    skip: !enabled,
    timeout: const Timeout(Duration(minutes: 3)),
  );
  test(
    'paired hidden targets preserve full camera history, estimates, goals and typed actions',
    () async {
      final histories = <List<Map<String, Object?>>>[];
      final maps = <String>[];
      for (final hidden in [-3.0, 3.0]) {
        final scenario = visualV2GuardScenario(hiddenTargetX: hidden);
        final env = GameTrainingEnvironment(
          runId: 'pair',
          environmentId: 'pair',
          scenarios: {scenario.id: scenario},
        );
        try {
          var result = await env.reset(seed: 11, scenario: scenario.id);
          final history = <Map<String, Object?>>[];
          maps.add(result.info['map_hash'] as String);
          for (var i = 0; i < 20; i++) {
            history.add({
              'observation': result.observations['actor']!.toList(),
              'estimate': result.info['teacher_estimate'],
              'goalTick': result.info['goal_observed_tick'],
              'actions': result.info['accepted_action'],
            });
            result = await env.step({
              'actor': Float32List.fromList(
                (result.info['teacher_estimate'] as List).cast<double>(),
              ),
            });
          }
          histories.add(history);
        } finally {
          await env.close();
        }
      }
      expect(maps[1], maps[0]);
      expect(histories[1], histories[0]);
    },
    skip: !enabled,
  );
}
