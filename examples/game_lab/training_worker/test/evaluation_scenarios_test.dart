import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/task_scenarios.dart';

void main() {
  test(
    'held-out worlds enforce split and expose actual physics outcomes',
    () async {
      final catalog = evaluationScenarioCatalog();
      final training = GameTrainingEnvironment(
        runId: 'deny',
        environmentId: 'deny',
        scenarios: catalog,
      );
      await expectLater(
        training.reset(seed: 10000, scenario: 'guard-evaluation'),
        throwsStateError,
      );
      await training.close();
      final env = GameTrainingEnvironment(
        runId: 'evaluation',
        environmentId: 'evaluation',
        scenarios: catalog,
        purpose: TrainingSplit.test,
      );
      addTearDown(env.close);
      final friction = <double>{};
      for (final id in [
        'guard-evaluation',
        'guard-memory',
        'vehicle-evaluation',
        'vehicle-recovery',
      ]) {
        for (final seed in [10000, 10001, 10002]) {
          var result = await env.reset(seed: seed, scenario: id);
          expect(result.info['split'], 'test');
          expect((result.info['scenario_spec'] as Map)['partition'], 'test');
          for (var tick = 0; tick < 70; tick++) {
            result = await env.step({
              'actor': Float32List.fromList(
                (result.info['baseline_action'] as List).cast<double>(),
              ),
            });
          }
          friction.add((result.info['physics_friction'] as num).toDouble());
          expect(result.info['collision'], isA<bool>());
          expect(result.info['physics_backend'], 'rapier');
        }
      }
      expect(friction.length, 3);
    },
  );
  test(
    'paired hidden positions produce identical permitted observations',
    () async {
      final env = GameTrainingEnvironment(
        runId: 'pair',
        environmentId: 'pair',
        scenarios: evaluationScenarioCatalog(),
        purpose: TrainingSplit.test,
      );
      addTearDown(env.close);
      final frames = <List<List<double>>>[];
      for (final side in ['left', 'right']) {
        var result = await env.reset(
          seed: 10000,
          scenario: 'guard-paired-$side',
        );
        final rows = <List<double>>[];
        for (var tick = 0; tick < 50; tick++) {
          rows.add(result.observations['actor']!.toList());
          result = await env.step({
            'actor': Float32List.fromList([2, 2, 3, 1, 0, 0]),
          });
        }
        frames.add(rows);
      }
      expect(frames[0], frames[1]);
    },
  );
}
