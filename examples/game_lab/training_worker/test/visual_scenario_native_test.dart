import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/visual_scenario.dart';

void main() {
  final enabled = Platform.environment['RUN_NATIVE_GPU'] == '1';
  test(
    'actual native camera modes share physical task clock and isolate teacher labels',
    () async {
      for (final vehicle in [false, true]) {
        for (final mode in TrainingCameraMode.values) {
          final scenario = visualTaskScenario(vehicle: vehicle, mode: mode);
          final env = GameTrainingEnvironment(
            runId: 'visual',
            environmentId: 'visual',
            scenarios: {scenario.id: scenario},
          );
          try {
            final initial = await env.reset(seed: 7, scenario: scenario.id);
            final imageWidth =
                84 *
                84 *
                (mode == TrainingCameraMode.rgb
                    ? 3
                    : mode == TrainingCameraMode.depth
                    ? 2
                    : 5);
            expect(initial.observations['actor']!.length, imageWidth + 8);
            expect(initial.info['visual_source'], 'actual-native-readback');
            expect(initial.info['camera_tick'], initial.info['tick']);
            expect(initial.info['camera_cpu_readback_ns'], greaterThan(0));
            expect(initial.info['camera_captures'], 1);
            final values = initial.observations['actor']!;
            expect(values.take(imageWidth).toSet().length, greaterThan(2));
            final schema = initial.info['observation_schema'] as Map;
            expect((schema['fields'] as List).map((f) => (f as Map)['name']), [
              'camera',
              'own-body',
            ]);
            expect(
              initial.info['training_only_fields'],
              contains('teacher_action'),
            );
            expect((initial.info['visual_profile'] as Map)['mode'], mode.name);
            final step = await env.step({
              'actor': Float32List.fromList(
                (initial.info['teacher_action'] as List)
                    .cast<num>()
                    .map((v) => v.toDouble())
                    .toList(),
              ),
            });
            expect(step.info['tick'], (initial.info['tick'] as int) + 1);
            expect(step.info['camera_tick'], step.info['tick']);
            expect(step.info['camera_world_revision'], step.info['tick']);
            expect(step.info['camera_captures'], 2);
          } finally {
            await env.close();
          }
        }
      }
    },
    skip: !enabled,
  );
  test(
    'hidden target displacement behind an actual opaque wall cannot alter student pixels',
    () async {
      final observations = <Float32List>[];
      for (final x in [-3.0, 3.0]) {
        final scenario = visualTaskScenario(
          vehicle: false,
          mode: TrainingCameraMode.combined,
          hiddenTargetX: x,
        );
        final env = GameTrainingEnvironment(
          runId: 'hidden',
          environmentId: 'hidden',
          scenarios: {scenario.id: scenario},
        );
        try {
          final initial = await env.reset(seed: 11, scenario: scenario.id);
          observations.add(initial.observations['actor']!);
        } finally {
          await env.close();
        }
      }
      expect(observations[1], orderedEquals(observations[0]));
    },
    skip: !enabled,
  );
  test(
    'privileged TRAIN teacher course is physically feasible at the pinned visual horizon',
    () async {
      for (final heldOut in [false, true]) {
        final scenario = visualTaskScenario(
          vehicle: false,
          mode: TrainingCameraMode.depth,
          heldOut: heldOut,
          split: heldOut ? TrainingSplit.test : TrainingSplit.training,
        );
        final env = GameTrainingEnvironment(
          runId: 'course',
          environmentId: 'course',
          scenarios: {scenario.id: scenario},
          purpose: heldOut ? TrainingSplit.test : TrainingSplit.training,
        );
        try {
          var result = await env.reset(
            seed: heldOut ? 1001 : 7,
            scenario: scenario.id,
          );
          var collision = false;
          for (var i = 0; i < 600; i++) {
            result = await env.step({
              'actor': Float32List.fromList(
                (result.info['teacher_action'] as List)
                    .cast<num>()
                    .map((v) => v.toDouble())
                    .toList(),
              ),
            });
            collision |= result.info['collision'] == true;
            if (result.terminated || result.truncated) break;
          }
          expect(result.info['success'], isTrue);
          expect(collision, isFalse);
          expect((result.info['scenario_spec'] as Map)['max_steps'], 600);
          expect(result.info['camera_tick'], result.info['tick']);
        } finally {
          await env.close();
        }
      }
    },
    skip: !enabled,
  );
  test(
    'visual stress catalog keeps validation separate and pins real course events',
    () async {
      final validation = visualScenarioCatalog(validation: true);
      final evaluation = visualScenarioCatalog(evaluation: true);
      expect(validation.keys.every((id) => id.endsWith('-validation')), isTrue);
      expect(
        validation.values.every((s) => s.split == TrainingSplit.validation),
        isTrue,
      );
      expect(
        evaluation.keys,
        containsAll([
          'guard-visual-depth-memory',
          'guard-visual-depth-recovery',
          'guard-visual-depth-paired-left',
          'guard-visual-depth-paired-right',
          'vehicle-visual-combined-recovery',
        ]),
      );
      expect(
        () => visualScenarioCatalog(validation: true, evaluation: true),
        throwsArgumentError,
      );
      for (final id in [
        'guard-visual-depth-memory',
        'guard-visual-depth-recovery',
      ]) {
        final scenario = evaluation[id]!;
        final env = GameTrainingEnvironment(
          runId: 'stress',
          environmentId: id,
          scenarios: {id: scenario},
          purpose: TrainingSplit.test,
        );
        try {
          var frame = await env.reset(seed: 20001, scenario: id);
          final settings =
              ((frame.info['scenario_spec'] as Map)['settings'] as Map);
          expect(settings['held_out_layout'], isNotNull);
          if (id.endsWith('-memory')) {
            expect(settings['target_speed'], .15);
          }
          if (id.endsWith('-recovery')) {
            expect(settings['curriculum_stage'], 'task-combinations');
          }
          var collisions = false;
          for (var tick = 0; tick < 600; tick++) {
            frame = await env.step({
              'actor': Float32List.fromList(
                (frame.info['teacher_action'] as List)
                    .cast<num>()
                    .map((v) => v.toDouble())
                    .toList(),
              ),
            });
            collisions |= frame.info['collision'] == true;
            if (frame.terminated || frame.truncated) break;
          }
          expect(frame.info['success'], isTrue, reason: id);
          expect(collisions, isFalse, reason: id);
          expect(
            frame.info['reward_progress_basis'],
            'remaining-distance-decrease',
          );
          expect(frame.info['task_remaining_distance'], lessThan(.75));
        } finally {
          await env.close();
        }
      }
      final scenario = validation['guard-visual-depth-validation']!;
      final env = GameTrainingEnvironment(
        runId: 'validation',
        environmentId: 'validation',
        scenarios: {scenario.id: scenario},
        purpose: TrainingSplit.validation,
      );
      try {
        final frame = await env.reset(seed: 1001, scenario: scenario.id);
        expect(frame.info['split'], 'validation');
        expect((frame.info['scenario_spec'] as Map)['partition'], 'validation');
      } finally {
        await env.close();
      }
    },
    skip: !enabled,
  );
}
