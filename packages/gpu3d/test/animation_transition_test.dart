import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'animation_test.dart' show movement;

void main() {
  test(
    'irregular frames preserve loop and completion results across reversals',
    () {
      for (final loop in AnimationLoop.values) {
        for (final speeds in [
          (1.2, -2.3),
          (-1.2, 2.3),
          (0.0, 2.0),
          (2.0, 0.0),
        ]) {
          for (final repetitions in [null, 2]) {
            AnimationAction run(List<int> steps) {
              final mixer = AnimationMixer(nodes: {});
              final action = mixer.play(
                AnimationClip(tracks: [], durationSeconds: .31),
                speed: speeds.$1,
                loop: loop,
                repetitions: repetitions,
              );
              action.warp(
                speeds.$1,
                speeds.$2,
                const Duration(milliseconds: 1200),
              );
              for (final ms in steps) {
                mixer.update(Duration(milliseconds: ms));
              }
              return action;
            }

            final whole = run([2000]), split = run([113, 97, 701, 1089]);
            expect(split.timeSeconds, closeTo(whole.timeSeconds, 1e-10));
            expect(split.completedRepetitions, whole.completedRepetitions);
            expect(split.isFinished, whole.isFinished);
            expect(split.speed, whole.speed);
          }
        }
      }
    },
  );

  test('fading a paused pose advances only its weight and releases demand', () {
    final node = Group();
    final mixer = AnimationMixer(nodes: {'part': node});
    final action = mixer.play(movement())
      ..seek(const Duration(seconds: 1))
      ..pause();
    action.fadeOut(const Duration(seconds: 2));
    expect(action.isFading, isTrue);
    expect(mixer.isAdvancing, isTrue);
    mixer.update(const Duration(milliseconds: 500));
    expect(action.weight, .75);
    expect(action.timeSeconds, 1);
    expect(mixer.nodes['part']!.position.x, 7.5);
    action.fadeTo(.5, const Duration(seconds: 1));
    mixer.update(const Duration(milliseconds: 500));
    expect(action.weight, .625);
    action.stopFading();
    expect(action.weight, .625);
    expect(mixer.isAdvancing, isFalse);
    action.fadeIn(const Duration(seconds: 1), weight: .8);
    expect(action.weight, 0);
    mixer.update(const Duration(seconds: 2));
    expect(action.weight, .8);
    expect(action.isFading, isFalse);
    expect(action.isPaused, isTrue);
    expect(mixer.isAdvancing, isFalse);
    expect(node.position.x, 8);
  });

  test(
    'crossfade schedules both actions atomically and pauses the outgoing clock',
    () {
      final node = Group();
      final mixer = AnimationMixer(nodes: {'part': node});
      final from = mixer.play(movement())
        ..seek(const Duration(seconds: 1))
        ..pause();
      final to = mixer.play(movement(end: 20), weight: 0)
        ..seek(const Duration(seconds: 1))
        ..pause();
      from.crossFadeTo(to, const Duration(seconds: 2));
      to.pause();
      mixer.update(const Duration(milliseconds: 500));
      expect(from.weight, .75);
      expect(to.weight, .25);
      expect(node.position.x, 12.5);
      mixer.update(const Duration(milliseconds: 1500));
      expect(from.weight, 0);
      expect(from.isPaused, isTrue);
      expect(to.weight, 1);
      expect(node.position.x, 20);
      expect(mixer.isAdvancing, isFalse);
      to.crossFadeTo(from, Duration.zero);
      expect(node.position.x, 10);
      expect(from.isPaused, isFalse);
      expect(to.isPaused, isTrue);
    },
  );

  test('a rejected blend preserves both fade clocks and playback state', () {
    final node = Group();
    final mixer = AnimationMixer(nodes: {'part': node});
    AnimationClip scale(double x) => AnimationClip(
      tracks: [
        VectorKeyframeTrack.scale(
          target: 'part',
          times: [0],
          values: [Vec3(x, 1, 1)],
        ),
      ],
    );
    final from = mixer.play(scale(1));
    final to = mixer.play(scale(-1), weight: 0);
    from.crossFadeTo(to, const Duration(seconds: 1));
    expect(
      () => mixer.update(const Duration(milliseconds: 500)),
      throwsArgumentError,
    );
    expect(from.weight, 1);
    expect(to.weight, 0);
    expect(from.isFading, isTrue);
    expect(node.scale, Vec3.one);
    mixer.update(const Duration(milliseconds: 250));
    expect(from.weight, .75);
    expect(to.weight, .25);
    expect(node.scale.x, .5);
  });

  test(
    'speed integration is invariant to frame partition and handles a sign change',
    () {
      for (final steps in [
        [2000],
        [500, 500, 500, 500],
        [1000, 1000],
      ]) {
        final mixer = AnimationMixer(nodes: {'part': Group()});
        final action = mixer.play(movement());
        action.warp(0, 2, const Duration(seconds: 2));
        for (final ms in steps) {
          mixer.update(Duration(milliseconds: ms));
        }
        expect(action.completedRepetitions, 2);
        expect(action.timeSeconds, closeTo(0, 1e-10));
        expect(action.speed, 2);
        expect(action.isWarping, isFalse);
        action.seek(const Duration(milliseconds: 500));
        action.warp(1, -1, const Duration(seconds: 2));
        for (final ms in steps) {
          mixer.update(Duration(milliseconds: ms));
        }
        expect(action.timeSeconds, closeTo(.5, 1e-10));
        expect(action.completedRepetitions, 1);
        expect(action.speed, -1);
      }
    },
  );

  test(
    'completion direction reflects the segment that reached the endpoint',
    () async {
      final mixer = AnimationMixer(nodes: {});
      final events = <AnimationEvent>[];
      final sub = mixer.events.listen(events.add);
      final action = mixer.play(
        AnimationClip(tracks: [], durationSeconds: .25),
        loop: AnimationLoop.once,
      );
      action.warp(1, -1, const Duration(seconds: 2));
      mixer.update(const Duration(seconds: 2));
      expect(action.isFinished, isTrue);
      expect(action.timeSeconds, .25);
      expect(action.speed, -1);
      await Future<void>.delayed(Duration.zero);
      expect(events.single, isA<AnimationFinishedEvent>());
      expect(events.single.direction, 1);
      await sub.cancel();
    },
  );

  test(
    'fade-out stops its clock at the fade endpoint even during a large update',
    () {
      for (final steps in [
        [3000],
        [250, 250, 250, 2250],
      ]) {
        final mixer = AnimationMixer(nodes: {'part': Group()});
        final action = mixer.play(movement());
        action.fadeOut(const Duration(milliseconds: 750));
        for (final ms in steps) {
          mixer.update(Duration(milliseconds: ms));
        }
        expect(action.timeSeconds, .75);
        expect(action.weight, 0);
        expect(action.isPaused, isTrue);
        expect(mixer.isAdvancing, isFalse);
      }
    },
  );

  test('halt, cancellation and manual setters retain their current values', () {
    final mixer = AnimationMixer(nodes: {'part': Group()});
    final action = mixer.play(movement());
    action.halt(const Duration(seconds: 1));
    mixer.update(const Duration(milliseconds: 500));
    expect(action.speed, .5);
    expect(action.timeSeconds, .375);
    action.stopWarping();
    mixer.update(const Duration(milliseconds: 500));
    expect(action.timeSeconds, .625);
    action.warpTo(0, const Duration(seconds: 1));
    mixer.update(const Duration(seconds: 2));
    expect(action.timeSeconds, .875);
    expect(action.speed, 0);
    expect(mixer.isAdvancing, isFalse);
    action.fadeTo(0, const Duration(seconds: 1));
    action.weight = .8;
    expect(action.isFading, isFalse);
    action.warpTo(2, const Duration(seconds: 1));
    action.speed = 1;
    expect(action.isWarping, isFalse);
  });

  test('warped crossfade matches normalized clip speeds', () {
    final mixer = AnimationMixer(nodes: {});
    final from = mixer.play(AnimationClip(tracks: [], durationSeconds: 2));
    final to = mixer.play(
      AnimationClip(tracks: [], durationSeconds: 4),
      weight: 0,
    );
    to.crossFadeFrom(from, const Duration(seconds: 2), warp: true);
    expect(from.speed, 1);
    expect(to.speed, 2);
    mixer.update(const Duration(seconds: 1));
    expect(from.speed, .75);
    expect(to.speed, 1.5);
    expect(from.timeSeconds, .875);
    expect(to.timeSeconds, 1.75);
    mixer.update(const Duration(seconds: 1));
    expect(from.timeSeconds, 1.5);
    expect(to.timeSeconds, 3);
    expect(from.isPaused, isTrue);
    expect(to.speed, 1);
  });

  test('invalid durations, ownership and warp ratios reject without edits', () {
    final mixer = AnimationMixer(nodes: {});
    final action = mixer.play(AnimationClip(tracks: [], durationSeconds: 1));
    final other = AnimationMixer(nodes: {}).play(action.clip);
    expect(
      () => action.crossFadeTo(other, const Duration(seconds: 1)),
      throwsArgumentError,
    );
    expect(
      () => action.crossFadeTo(action, const Duration(seconds: 1)),
      throwsArgumentError,
    );
    expect(() => action.fadeTo(2, Duration.zero), throwsArgumentError);
    expect(
      () => action.fadeOut(const Duration(microseconds: -1)),
      throwsArgumentError,
    );
    expect(
      () => action.halt(const Duration(seconds: 1000000001)),
      throwsArgumentError,
    );
    expect(
      () => action.warp(double.nan, 1, Duration.zero),
      throwsArgumentError,
    );
    final tiny = mixer.play(
      AnimationClip(tracks: [], durationSeconds: 1e-9),
      weight: 0,
    );
    expect(
      () => action.crossFadeTo(tiny, const Duration(seconds: 1), warp: true),
      throwsArgumentError,
    );
    expect(action.isFading, isFalse);
    expect(tiny.isWarping, isFalse);
    action.stop();
    expect(() => action.fadeIn(Duration.zero), throwsStateError);
  });
}
