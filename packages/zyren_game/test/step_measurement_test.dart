import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'session_test.dart' as fixture;

void _work() {
  final watch = Stopwatch()..start();
  while (watch.elapsedMicroseconds < 3000) {}
}

void main() {
  test(
    'full step measurement includes mutations systems and state observers',
    () async {
      final order = <String>[];
      final measurements = <(int, Duration)>[];
      late GameSession session;
      session = GameSession(
        project: fixture.recipe(),
        seed: 1,
        systems: [
          fixture.Probe(
            'input',
            GamePhase.commands,
            order,
            update: (_) => _work(),
          ),
          fixture.Probe(
            'physics',
            GamePhase.physics,
            order,
            update: (_) => _work(),
          ),
        ],
        onStepMeasured: (tick, elapsed) {
          order.add('measured:$tick');
          expect(
            order.lastIndexOf('observer:$tick'),
            lessThan(order.length - 1),
          );
          expect(session.isStepping, isTrue);
          expect(() => session.step(), throwsStateError);
          measurements.add((tick, elapsed));
        },
      );
      session.listenState(() {
        order.add('observer:${session.tick}');
        _work();
      });
      session.enqueueMutation((_) {
        order.add('mutation');
        _work();
      });
      session.step();
      expect(measurements.single.$1, 1);
      expect(
        measurements.single.$2.inMicroseconds,
        greaterThanOrEqualTo(12000),
      );
      expect(order, [
        'start:input',
        'start:physics',
        'mutation',
        'input:1',
        'physics:1',
        'observer:1',
        'measured:1',
      ]);
      session.pause();
      session.step();
      expect(measurements, hasLength(1));
      session.resume();
      session.advance(session.stepSeconds * 2);
      expect(measurements.map((m) => m.$1), [1, 2, 3]);
      await session.close();
    },
  );

  test(
    'measurement observer failure fails closed and session remains closable',
    () async {
      final session = GameSession(
        project: fixture.recipe(),
        seed: 1,
        onStepMeasured: (_, _) => throw StateError('measurement consumer'),
      );
      expect(() => session.step(), throwsStateError);
      expect(session.isStepping, isFalse);
      expect(session.fault, isA<StateError>());
      expect(() => session.step(), throwsStateError);
      await session.close();
    },
  );
}
