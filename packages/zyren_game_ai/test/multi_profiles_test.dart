import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  test(
    'team profiles pin actual A3 perception and A7 historical message budgets',
    () {
      final hashes = <String>{};
      for (final task in ['cooperative-search', 'competitive-pursuit']) {
        final profile = TrainingMultiProfiles.forTask(task: task);
        expect(profile.spec.width, profile.assembler.spec.width + 10);
        expect(profile.spec.configurationHash, profile.configurationHash);
        expect(profile.spec.latencyTicks, 1);
        expect(profile.spec.cadenceTicks, 1);
        expect(profile.fixedHz, 50);
        expect(profile.maxHoldTicks, 2);
        expect(profile.communication.delayTicks, 2);
        expect(profile.communication.ttlTicks, 100);
        expect(profile.communication.maxPending, 8);
        expect(profile.perception.maxEntities, 3);
        expect(profile.decoder.spec.hash, TrainingActions.character.hash);
        expect(
          TrainingMultiProfiles.fromJson(profile.toJson()).spec.hash,
          profile.spec.hash,
        );
        expect(hashes.add(profile.spec.hash), isTrue);
        expect(profile.toJson()['version'], 2);
        expect(profile.toJson()['message_cadence_ticks'], 5);
        expect(
          profile.toJson()['message_target'],
          task == 'cooperative-search'
              ? 'authored-goal-visible-handle'
              : 'none',
        );
        expect(
          profile.toJson()['role_names'],
          task == 'cooperative-search'
              ? {'positive': 'scout', 'negative': 'searcher'}
              : {'positive': 'pursuer', 'negative': 'evader'},
        );
        expect(profile.toJson()['masks'], {
          'jump': 'grounded-only',
          'interact': false,
        });
        final altered = {...profile.toJson(), 'teacher_pose': 'live-target'};
        expect(
          () => TrainingMultiProfiles.fromJson(altered),
          throwsFormatException,
        );
        expect(profile.toJson()['actor_input_exclusions'], [
          'state',
          'teacher_actions',
          'distances',
        ]);
      }
      expect(
        () => TrainingMultiProfiles.forTask(task: 'private-state'),
        throwsArgumentError,
      );
    },
  );
}
