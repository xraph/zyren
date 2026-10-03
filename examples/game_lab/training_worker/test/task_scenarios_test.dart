import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/task_scenarios.dart';

void main() {
  test(
    'all authored curriculum stages run real physics with shared profiles',
    () async {
      final env = GameTrainingEnvironment(
        runId: 'curriculum',
        environmentId: 'curriculum',
        scenarios: taskScenarioCatalog(),
      );
      addTearDown(env.close);
      final builds = <String>{};
      for (final family in ['guard', 'vehicle']) {
        for (final stage in trainingCurriculumStages) {
          final id = '$family-$stage';
          var result = await env.reset(seed: 7, scenario: id);
          final spec = result.info['scenario_spec'] as Map;
          expect((spec['settings'] as Map)['curriculum_stage'], stage);
          builds.add(spec['game_build_hash'] as String);
          for (var i = 0; i < 70; i++) {
            result = await env.step({
              'actor': Float32List.fromList(
                (result.info['baseline_action'] as List).cast<double>(),
              ),
            });
          }
          expect(
            result.observations['actor']!.length,
            family == 'guard' ? 14 : 10,
          );
          expect(result.info['physics_backend'], 'rapier');
        }
      }
      expect(builds.length, 10);
    },
  );

  test(
    'real guard motor baseline pursues then investigates captured position',
    () async {
      final env = GameTrainingEnvironment(
        runId: 'guard-test',
        environmentId: 'guard',
        scenarios: {'guard': guardScenario()},
      );
      addTearDown(env.close);
      var result = await env.reset(seed: 7, scenario: 'guard');
      final modes = <String>{};
      final positions = <double>[];
      expect(result.observations['actor']!.length, 14);
      expect(result.info['action_space'], {
        'kind': 'multi_discrete',
        'nvec': [5, 5, 5, 3, 2, 2],
      });
      expect(env.snapshot, throwsStateError);
      for (var i = 0; i < 240; i++) {
        result = await env.step({
          'actor': Float32List.fromList(
            (result.info['baseline_action'] as List).cast<double>(),
          ),
        });
        modes.add(result.info['task_mode'] as String);
        positions.add(
          ((result.info['physics_position'] as List)[2] as num).toDouble(),
        );
      }
      expect(modes, containsAll(['pursuit', 'investigation']));
      expect(positions.last, greaterThan(.2));
      expect(result.terminated, isTrue);
      expect(result.info['renderer'], isNull);
    },
  );
  test(
    'real vehicle pedals prioritize braking and scripted segment turns',
    () async {
      final env = GameTrainingEnvironment(
        runId: 'vehicle-test',
        environmentId: 'vehicle',
        scenarios: {'vehicle': vehicleScenario()},
      );
      addTearDown(env.close);
      var result = await env.reset(seed: 7, scenario: 'vehicle');
      expect(result.observations['actor']!.length, 10);
      for (var i = 0; i < 100; i++) {
        result = await env.step({
          'actor': Float32List.fromList(
            (result.info['baseline_action'] as List).cast<double>(),
          ),
        });
      }
      final before = (result.info['physics_position'] as List).cast<num>();
      expect(before[0].abs(), greaterThan(.01));
      result = await env.step({
        'actor': Float32List.fromList([.25, .7, .8]),
      });
      expect((result.info['accepted_action'] as List)[0], .25);
      expect((result.info['accepted_action'] as List)[1], 0);
      expect((result.info['accepted_action'] as List)[2], closeTo(.8, 1e-7));
      for (var i = 101; i < 240; i++) {
        result = await env.step({
          'actor': Float32List.fromList(
            (result.info['baseline_action'] as List).cast<double>(),
          ),
        });
      }
      expect((result.info['accepted_action'] as List)[2], 1);
      expect(result.info['grounded_wheels'], greaterThan(0));
      expect(result.terminated, isTrue);
      expect(result.info['physics_backend'], 'rapier');
    },
  );
}
