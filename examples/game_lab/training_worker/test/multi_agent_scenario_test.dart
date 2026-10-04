import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_lab_training_worker/multi_agent_scenario.dart';

void main() {
  test(
    'shared native controllers move both agents and delayed team messages retain capture provenance',
    () async {
      final scenario = multiAgentScenario();
      final env = GameTrainingEnvironment(
        runId: 'multi',
        environmentId: 'multi',
        scenarios: {scenario.id: scenario},
      );
      try {
        var result = await env.reset(seed: 7, scenario: scenario.id);
        expect(result.info['actor_ids'], ['a', 'b']);
        final contract = TrainingMultiProfiles.fromJson(
          (result.info['multi_profile'] as Map).cast<String, Object?>(),
        );
        expect(result.info['observation_schema_hash'], contract.spec.hash);
        expect(result.info['observation_schema'], contract.spec.toJson());
        expect(result.observations['a']!.length, contract.spec.width);
        final initialState = List<double>.from(
          ((result.info['training_only'] as Map)['state'] as List)
              .cast<double>(),
        );
        for (var i = 0; i < 30; i++) {
          final teachers =
              (result.info['training_only'] as Map)['teacher_actions'] as Map;
          result = await env.step({
            for (final a in result.info['actor_ids'] as List)
              a as String: Float32List.fromList(
                (teachers[a] as List).cast<double>(),
              ),
          });
        }
        final state = ((result.info['training_only'] as Map)['state'] as List)
            .cast<double>();
        expect(state[2], greaterThan(initialState[2]));
        expect(state[5], greaterThan(initialState[5]));
        expect(result.info['team_messages_sent'], greaterThan(0));
        expect(result.info['team_messages_delivered'], greaterThan(0));
        expect(result.info['tick'], 31);
        expect(
          result.observations.values.any(
            (v) => v.sublist(v.length - 6).contains(1),
          ),
          isTrue,
        );
        expect(
          (result.info['observation_schema'] as Map)['fields'],
          everyElement(isNot(containsPair('id', 'teacher_actions'))),
        );
      } finally {
        await env.close();
      }
    },
  );
  test(
    'native controllable membership admits guest and removes it with terminal outcome',
    () async {
      final scenario = multiAgentScenario(dynamic: true);
      final env = GameTrainingEnvironment(
        runId: 'dynamic',
        environmentId: 'dynamic',
        scenarios: {scenario.id: scenario},
      );
      try {
        var result = await env.reset(seed: 7, scenario: scenario.id);
        for (var i = 0; i < 10; i++) {
          result = await env.step({
            for (final a in result.info['actor_ids'] as List)
              a as String: Float32List.fromList([2, 2, 2, 1, 0, 0]),
          });
          if (i == 4) expect(result.info['actor_ids'], contains('guest'));
        }
        expect(result.info['actor_ids'], isNot(contains('guest')));
        expect(result.info['native_active_actor_ids'], ['a', 'b']);
        expect((result.info['per_agent_terminated'] as Map)['guest'], isTrue);
        final terminal = result.info['terminal_observations'] as Map;
        expect(terminal.keys, ['guest']);
        expect(
          (terminal['guest'] as List).length,
          result.observations['a']!.length,
        );
        expect(
          (terminal['guest'] as List).cast<double>().every((v) => v.isFinite),
          isTrue,
        );
        await expectLater(
          env.step({
            'a': Float32List.fromList([2, 2, 2, 1, 0, 0]),
            'b': Float32List.fromList([2, 2, 2, 1, 0, 0]),
            'guest': Float32List.fromList([2, 2, 2, 1, 0, 0]),
          }),
          throwsArgumentError,
        );
      } finally {
        await env.close();
      }
    },
  );
}
