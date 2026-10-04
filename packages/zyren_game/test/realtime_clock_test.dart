import 'dart:async';
import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'session_test.dart' show recipe, Probe;

void main() {
  test('50 Hz timer advances without rendering and admits worker replies', () {
    fakeAsync((time) {
      final ready = <int>{}, consumed = <int>[];
      final session = GameSession(
        project: recipe(hz: 50),
        seed: 1,
        systems: [
          Probe(
            'policy',
            GamePhase.commands,
            [],
            update: (session) {
              if (ready.remove(session.tick)) consumed.add(session.tick);
              final due = session.tick + 1;
              Timer(const Duration(milliseconds: 3), () => ready.add(due));
            },
          ),
        ],
      );
      final clock = GameRealtimeClock(session, elapsed: () => time.elapsed);
      final wakeups = <GameClockWake>[];
      clock.measurements.listen(wakeups.add);
      clock.setActive(true);
      expect(() => GameRealtimeClock(session), throwsStateError);
      expect(() => session.advance(.02), throwsStateError);
      expect(() => session.step(), throwsStateError);
      time.elapse(const Duration(seconds: 1));
      expect(session.tick, 50);
      expect(consumed, List.generate(49, (i) => i + 2));
      expect(wakeups.where((wake) => wake.advanced).length, 50);
      expect(clock.maximumLatenessMicros, 0);
      expect(session.droppedSeconds, 0);
      clock.dispose();
      time.elapse(const Duration(seconds: 1));
      expect(session.tick, 50);
      expect(session.realtimeClock, isNull);
      session.advance(.02);
      expect(session.tick, 51);
      unawaited(session.close());
      time.flushTimers();
    });
  });

  test('catch-up yields callbacks and bounds discarded wall time', () {
    fakeAsync((time) {
      final order = <String>[];
      final session = GameSession(
        project: recipe(hz: 50),
        seed: 1,
        maxCatchUpSteps: 3,
        systems: [
          Probe(
            'work',
            GamePhase.commands,
            [],
            update: (s) {
              order.add('tick${s.tick}');
              if (s.tick == 1) {
                time.elapseBlocking(const Duration(milliseconds: 200));
                Timer.run(() => order.add('reply'));
              }
            },
          ),
        ],
      );
      final clock = GameRealtimeClock(session, elapsed: () => time.elapsed);
      clock.setActive(true);
      time.elapse(const Duration(milliseconds: 20));
      time.elapse(const Duration(milliseconds: 1));
      clock.dispose();
      expect(order.indexOf('reply'), lessThan(order.indexOf('tick2')));
      expect(session.droppedSeconds, greaterThanOrEqualTo(.14));
      unawaited(session.close());
    });
  });

  test('visibility, pause and epoch changes discard suspended time', () {
    fakeAsync((time) {
      final session = GameSession(project: recipe(hz: 50), seed: 1);
      final clock = GameRealtimeClock(session, elapsed: () => time.elapsed);
      clock.setActive(true);
      time.elapse(const Duration(milliseconds: 40));
      expect(session.tick, 2);
      final epoch = session.epoch;
      clock.setActive(false);
      expect(session.epoch, greaterThan(epoch));
      time.elapse(const Duration(minutes: 1));
      expect(session.tick, 2);
      clock.setActive(true);
      time.elapse(const Duration(milliseconds: 19));
      expect(session.tick, 2);
      time.elapse(const Duration(milliseconds: 1));
      expect(session.tick, 3);
      session.pause();
      session.stepOnce();
      expect(session.tick, 4);
      expect(session.paused, isTrue);
      expect(clock.running, isFalse);
      time.elapse(const Duration(seconds: 1));
      expect(session.tick, 4);
      session.resume();
      session.invalidatePending();
      time.elapse(const Duration(milliseconds: 20));
      expect(session.tick, 4);
      time.elapse(const Duration(milliseconds: 20));
      expect(session.tick, 5);
      expect(session.droppedSeconds, 0);
      unawaited(session.close());
      expect(clock.isClosed, isTrue);
      time.flushTimers();
    });
  });

  test('step failure stops scheduling and reports the original error', () {
    fakeAsync((time) {
      final failure = StateError('system failed');
      final errors = <Object>[];
      final session = GameSession(
        project: recipe(hz: 50),
        seed: 1,
        systems: [
          Probe('broken', GamePhase.commands, [], update: (_) => throw failure),
        ],
      );
      final clock = GameRealtimeClock(
        session,
        elapsed: () => time.elapsed,
        onError: (error, _) => errors.add(error),
      );
      clock.setActive(true);
      time.elapse(const Duration(seconds: 1));
      expect(errors, [same(failure)]);
      expect(session.fault, same(failure));
      expect(clock.running, isFalse);
      expect(session.tick, 1);
      unawaited(session.close());
      time.flushTimers();
    });
  });
}
