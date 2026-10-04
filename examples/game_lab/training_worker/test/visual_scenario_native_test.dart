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
            expect((schema['fields'] as List).map((f) => (f as Map)['id']), [
              'camera',
              'own-body',
            ]);
            expect(schema['training_only_fields'], contains('teacher_action'));
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
}
