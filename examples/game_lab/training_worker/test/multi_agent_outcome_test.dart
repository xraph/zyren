import 'package:test/test.dart';
import 'package:zyren_game_lab_training_worker/multi_agent_outcome.dart';

void main() {
  test('competitive capture and legal timeout have exclusive role winners', () {
    final capture = MultiTaskOutcome.competitive(
      captured: true,
      timedOut: false,
      legal: true,
    );
    expect(capture.ended, isTrue);
    expect(capture.results, {'a': 'win', 'b': 'loss'});
    final survived = MultiTaskOutcome.competitive(
      captured: false,
      timedOut: true,
      legal: true,
    );
    expect(survived.results, {'a': 'loss', 'b': 'win'});
    expect(
      MultiTaskOutcome.competitive(
        captured: true,
        timedOut: true,
        legal: true,
      ).results,
      {'a': 'win', 'b': 'loss'},
    );
  });

  test(
    'out-of-arena survival cannot win and unfinished play cannot terminate',
    () {
      for (final captured in [false, true]) {
        final invalid = MultiTaskOutcome.competitive(
          captured: captured,
          timedOut: true,
          legal: false,
        );
        expect(invalid.results, {'a': 'draw', 'b': 'draw'});
        expect(invalid.legal, isFalse);
        expect(invalid.ended, isTrue);
      }
      final pending = MultiTaskOutcome.competitive(
        captured: false,
        timedOut: false,
        legal: true,
      );
      expect(pending.ended, isFalse);
      expect(pending.results, {'a': 'pending', 'b': 'pending'});
      expect(() => pending.results['a'] = 'win', throwsUnsupportedError);
    },
  );

  test('cooperative credit requires the whole registered team', () {
    final incomplete = MultiTaskOutcome.cooperative(
      actors: const ['a', 'b'],
      reached: const {'a'},
      timedOut: true,
      legal: true,
    );
    expect(incomplete.results, {'a': 'loss', 'b': 'loss'});
    final complete = MultiTaskOutcome.cooperative(
      actors: const ['a', 'b'],
      reached: const {'a', 'b'},
      timedOut: false,
      legal: true,
    );
    expect(complete.results, {'a': 'win', 'b': 'win'});
    expect(complete.ended, isTrue);
    expect(
      () => MultiTaskOutcome.cooperative(
        actors: const ['a', 'a'],
        reached: const {},
        timedOut: false,
        legal: true,
      ),
      throwsArgumentError,
    );
  });
}
