import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_lab_training_worker/multi_agent_scenario.dart';

void main() {
  for (final competitive in [false, true]) {
    test(
      'hidden ${competitive ? 'opponent' : 'goal'} changes no scout input before authorized delivery',
      () async {
        final environments = <GameTrainingEnvironment>[];
        final histories = <List<Float32List>>[];
        final privileged = <Object?>[];
        try {
          for (final variant in ['left', 'right']) {
            final scenario = multiAgentScenario(
              competitive: competitive,
              split: TrainingSplit.test,
              heldOut: true,
              hiddenPair: variant,
            );
            final env = GameTrainingEnvironment(
              runId: 'hidden-$variant',
              environmentId: 'hidden-$variant',
              purpose: TrainingSplit.test,
              scenarios: {scenario.id: scenario},
            );
            environments.add(env);
            var result = await env.reset(seed: 7, scenario: scenario.id);
            privileged.add((result.info['training_only'] as Map)['distances']);
            final rows = <Float32List>[];
            for (var tick = 0; tick < 4; tick++) {
              rows.add(Float32List.fromList(result.observations['a']!));
              expect(result.info['team_messages_delivered'], 0);
              result = await env.step({
                for (final actor in result.observations.keys)
                  actor: Float32List.fromList([2, 2, 2, 1, 0, 0]),
              });
            }
            histories.add(rows);
          }
          expect(privileged[0], isNot(equals(privileged[1])));
          for (var tick = 0; tick < 4; tick++) {
            expect(histories[0][tick], orderedEquals(histories[1][tick]));
          }
        } finally {
          for (final env in environments) {
            await env.close();
          }
        }
      },
    );
  }
}
