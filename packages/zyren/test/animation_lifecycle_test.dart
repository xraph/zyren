import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'animation_test.dart' show movement;

Future<void> flushEvents() => Future<void>.delayed(Duration.zero);

void main() {
  test('finite repeat commits its endpoint and sends one completion', () async {
    final node = Group();
    final mixer = AnimationMixer(nodes: {'part': node});
    final events = <AnimationEvent>[];
    final subscription = mixer.events.listen(events.add);
    final action = mixer.play(movement(), repetitions: 3);
    mixer.update(const Duration(milliseconds: 2250));
    expect(action.timeSeconds, .25);
    expect(action.completedRepetitions, 2);
    expect(events, isEmpty);
    await flushEvents();
    final loop = events.single as AnimationLoopEvent;
    expect(loop.repetitionsDelta, 2);
    expect(loop.completedRepetitions, 2);
    expect(loop.timeSeconds, .25);
    mixer.update(const Duration(days: 1));
    expect(action.isFinished, isTrue);
    expect(action.timeSeconds, 1);
    expect(action.completedRepetitions, 3);
    expect(mixer.isAdvancing, isFalse);
    await flushEvents();
    final finished = events.last as AnimationFinishedEvent;
    expect(finished.action, same(action));
    expect(finished.direction, 1);
    expect(finished.timeSeconds, 1);
    mixer.update(const Duration(days: 1));
    await flushEvents();
    expect(events, hasLength(2));
    await subscription.cancel();
    final isolated = AnimationMixer(nodes: {'part': node});
    isolated.play(movement(), repetitions: 1);
    isolated.update(const Duration(seconds: 1));
    expect(node.position.x, 10);
  });

  test('ping-pong counts legs and reverse repeats finish at zero', () async {
    for (final loop in [AnimationLoop.repeat, AnimationLoop.pingPong]) {
      for (final speed in [-1.0, 1.0]) {
        for (final count in [1, 2, 3, 4]) {
          final node = Group(),
              mixer = AnimationMixer(nodes: {'part': Group()});
          final events = <AnimationEvent>[];
          final sub = mixer.events.listen(events.add);
          final action = mixer.play(
            movement(),
            loop: loop,
            speed: speed,
            repetitions: count,
          );
          mixer.update(Duration(seconds: count));
          final end = loop == AnimationLoop.repeat || count.isOdd
              ? (speed > 0 ? 1.0 : 0.0)
              : (speed > 0 ? 0.0 : 1.0);
          expect(
            action.timeSeconds,
            end,
            reason: '$loop, speed $speed, count $count',
          );
          expect(action.isFinished, isTrue);
          expect(action.completedRepetitions, count);
          await flushEvents();
          expect(events, hasLength(1));
          expect(
            (events.single as AnimationFinishedEvent).direction,
            speed.toInt(),
          );
          await sub.cancel();
          // Stepwise and one-shot advancement must agree at exact endpoints.
          final second = AnimationMixer(nodes: {'part': node});
          final other = second.play(
            movement(),
            loop: loop,
            speed: speed,
            repetitions: count,
          );
          for (var i = 0; i < count * 4; i++) {
            second.update(const Duration(milliseconds: 250));
          }
          expect(other.timeSeconds, end);
          expect(other.completedRepetitions, count);
          expect(other.isFinished, isTrue);
        }
      }
    }
  });

  test(
    'seeking, loop edits and replay reset counts without synthetic events',
    () async {
      final mixer = AnimationMixer(nodes: {'part': Group()});
      final events = <AnimationEvent>[];
      final sub = mixer.events.listen(events.add);
      final action = mixer.play(movement(), repetitions: 3);
      mixer.update(const Duration(seconds: 1));
      await flushEvents();
      action.seek(const Duration(milliseconds: 500));
      expect(action.completedRepetitions, 0);
      action.pause();
      action.resume();
      mixer.update(const Duration(milliseconds: 500));
      expect(action.completedRepetitions, 1);
      action.repetitions = 2;
      expect(action.completedRepetitions, 0);
      action.loop = AnimationLoop.pingPong;
      mixer.update(const Duration(seconds: 2));
      expect(action.isFinished, isTrue);
      action.resume();
      expect(action.completedRepetitions, 0);
      expect(action.isFinished, isFalse);
      action.stop();
      await flushEvents();
      expect(events, hasLength(3));
      expect(() => action.repetitions = 1, throwsStateError);
      await sub.cancel();
    },
  );

  test(
    'failed pose cannot publish completion or consume repeat counts',
    () async {
      final node = Group();
      final mixer = AnimationMixer(nodes: {'part': node});
      final events = <AnimationEvent>[];
      final sub = mixer.events.listen(events.add);
      final action = mixer.play(movement(), repetitions: 1);
      final bad = mixer.play(
        AnimationClip(
          tracks: [
            VectorKeyframeTrack.scale(
              target: 'part',
              times: [0, 2],
              values: [Vec3.one, const Vec3(-1, 1, 1)],
            ),
          ],
        ),
      );
      expect(
        () => mixer.update(const Duration(seconds: 1)),
        throwsArgumentError,
      );
      expect(action.timeSeconds, 0);
      expect(action.completedRepetitions, 0);
      expect(action.isFinished, isFalse);
      await flushEvents();
      expect(events, isEmpty);
      expect(node.position, Vec3.zero);
      bad.stop();
      mixer.update(const Duration(seconds: 1));
      await flushEvents();
      expect(events.single, isA<AnimationFinishedEvent>());
      expect(node.position.x, 10);
      await sub.cancel();
    },
  );

  test(
    'zero duration reports completion after play returns; callbacks can replace actions',
    () async {
      final node = Group();
      final mixer = AnimationMixer(nodes: {'part': node});
      late AnimationAction replacement;
      var returned = false;
      final sub = mixer.events.listen((event) {
        expect(returned, isTrue);
        expect(event, isA<AnimationFinishedEvent>());
        event.action.stop();
        replacement = mixer.play(movement());
      });
      final zero = mixer.play(AnimationClip(tracks: []), repetitions: 100);
      returned = true;
      expect(zero.isFinished, isTrue);
      await flushEvents();
      expect(zero.isStopped, isTrue);
      expect(mixer.actions, [replacement]);
      expect(mixer.isAdvancing, isTrue);
      await sub.cancel();
      expect(node.position, Vec3.zero);
    },
  );

  test(
    'reverse boundary departures do not double count and events keep snapshots',
    () async {
      final mixer = AnimationMixer(nodes: {'part': Group()});
      final events = <AnimationEvent>[];
      final sub = mixer.events.listen(events.add);
      final action = mixer.play(
        movement(),
        loop: AnimationLoop.pingPong,
        repetitions: 3,
      );
      mixer.update(const Duration(seconds: 1));
      action.speed = -1;
      mixer.update(const Duration(milliseconds: 250));
      expect(action.timeSeconds, .75);
      expect(action.completedRepetitions, 1);
      mixer.update(const Duration(milliseconds: 750));
      expect(action.timeSeconds, 0);
      expect(action.completedRepetitions, 2);
      mixer.update(const Duration(seconds: 1));
      expect(action.timeSeconds, 1);
      expect(action.isFinished, isTrue);
      action.seek(const Duration(milliseconds: 500));
      await flushEvents();
      expect(events.map((e) => e.timeSeconds), [1, 0, 1]);
      expect(events.map((e) => e.completedRepetitions), [1, 2, 3]);
      expect(events.map((e) => e.direction), [1, -1, -1]);
      expect(action.timeSeconds, .5);
      await sub.cancel();
    },
  );

  test(
    'finite tiny clips clamp before counter overflow; infinite ones reject atomically',
    () {
      final mixer = AnimationMixer(nodes: {'part': Group()});
      final clip = AnimationClip(tracks: [], durationSeconds: 1e-300);
      final finite = mixer.play(clip, repetitions: 1000000000);
      mixer.update(const Duration(days: 1));
      expect(finite.isFinished, isTrue);
      expect(finite.completedRepetitions, 1000000000);
      final infinite = mixer.play(clip);
      expect(() => mixer.update(const Duration(days: 1)), throwsArgumentError);
      expect(infinite.completedRepetitions, 0);
      expect(infinite.timeSeconds, 0);
    },
  );

  test(
    'fractional durations finish consistently after split elapsed steps',
    () {
      for (final loop in AnimationLoop.values) {
        for (final speed in [-1.0, 1.0]) {
          final runs = loop == AnimationLoop.once ? 1 : 3;
          final mixer = AnimationMixer(nodes: {});
          final action = mixer.play(
            AnimationClip(tracks: [], durationSeconds: .1),
            loop: loop,
            speed: speed,
            repetitions: 3,
          );
          for (var run = 0; run < runs; run++) {
            for (final milliseconds in [30, 30, 40]) {
              mixer.update(Duration(milliseconds: milliseconds));
            }
          }
          expect(action.isFinished, isTrue, reason: '$loop / $speed');
          expect(action.completedRepetitions, runs);
          expect(action.timeSeconds, speed > 0 ? .1 : 0);
        }
      }
    },
  );

  test('invalid repeat counts fail without changing actions', () {
    final mixer = AnimationMixer(nodes: {'part': Group()});
    final action = mixer.play(movement(), repetitions: 2);
    for (final value in [0, -1, 1000000001]) {
      expect(
        () => mixer.play(movement(), repetitions: value),
        throwsArgumentError,
      );
      expect(() => action.repetitions = value, throwsArgumentError);
    }
    expect(mixer.actions, [action]);
    expect(action.repetitions, 2);
    action.repetitions = null;
    mixer.update(const Duration(seconds: 100));
    expect(action.isFinished, isFalse);
    expect(action.completedRepetitions, 100);
  });
}
