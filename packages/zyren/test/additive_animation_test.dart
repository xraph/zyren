import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'animation_test.dart' show movement;
import 'morph_animation_test.dart' show morphMesh;

void expectRotation(Quat actual, Quat expected) {
  for (final axis in [
    const Vec3(1, 0, 0),
    const Vec3(0, 1, 0),
    const Vec3(0, 0, 1),
  ]) {
    expect(
      (actual.rotate(axis) - expected.rotate(axis)).length,
      lessThan(1e-10),
    );
  }
}

void main() {
  test(
    'normal and additive actions keep separate clocks and demand states',
    () async {
      final node = Group();
      final mixer = AnimationMixer(nodes: {'part': node});
      final events = <AnimationEvent>[];
      final sub = mixer.events.listen(events.add);
      final base = mixer.play(movement(), loop: AnimationLoop.once);
      final layer = mixer.play(
        movement(),
        blendMode: AnimationBlendMode.additive,
        weight: .5,
        speed: 2,
        loop: AnimationLoop.once,
      );
      mixer.update(const Duration(milliseconds: 250));
      expect(mixer.nodes['part']!.position.x, 5);
      expect(base.timeSeconds, .25);
      expect(layer.timeSeconds, .5);
      layer.pause();
      mixer.update(const Duration(milliseconds: 250));
      expect(mixer.nodes['part']!.position.x, 7.5);
      base.pause();
      expect(mixer.isAdvancing, isFalse);
      layer.resume();
      expect(mixer.isAdvancing, isTrue);
      mixer.update(const Duration(milliseconds: 250));
      expect(mixer.nodes['part']!.position.x, 10);
      expect(layer.isFinished, isTrue);
      expect(mixer.isAdvancing, isFalse);
      await Future<void>.delayed(Duration.zero);
      expect(events.single.action, same(layer));
      layer.stop();
      expect(mixer.nodes['part']!.position.x, 5);
      await sub.cancel();
      expect(node.position.x, 5);
    },
  );

  test('one overflowing morph primitive rejects the complete layered pose', () {
    final a = morphMesh()..morphWeights = [999999, 0], b = morphMesh();
    final group = Group();
    final mixer = AnimationMixer(
      nodes: {'part': group},
      morphTargets: {
        'part': [a, b],
      },
    );
    final action = mixer.play(
      AnimationClip(
        tracks: [
          ...movement().tracks,
          MorphWeightKeyframeTrack(
            target: 'part',
            times: [0, 1],
            values: [
              [0, 0],
              [2, 0],
            ],
          ),
        ],
      ),
      blendMode: AnimationBlendMode.additive,
    );
    expect(() => action.seek(const Duration(seconds: 1)), throwsArgumentError);
    expect(action.timeSeconds, 0);
    expect(group.position, Vec3.zero);
    expect(a.morphWeights, [999999, 0]);
    expect(b.morphWeights, [0, 0]);
  });

  test(
    'offset layers apply after the normal blend without normalizing their weights',
    () {
      for (final overlayFirst in [false, true]) {
        final node = Group()..position = const Vec3(2, 0, 0);
        final mixer = AnimationMixer(nodes: {'part': node});
        final clip = movement();
        AnimationAction? base;
        if (!overlayFirst) {
          base = mixer.play(clip, weight: .5)..seek(const Duration(seconds: 1));
        }
        final overlay = mixer.play(
          clip,
          blendMode: AnimationBlendMode.additive,
          weight: .5,
          referenceTime: const Duration(milliseconds: 500),
        )..seek(const Duration(seconds: 1));
        base ??= mixer.play(clip, weight: .5)..seek(const Duration(seconds: 1));
        expect(node.position.x, 8.5); // .5*10 + .5*2 + .5*(10-5)
        final second = mixer.play(
          clip,
          blendMode: AnimationBlendMode.additive,
          weight: .5,
        )..seek(const Duration(seconds: 1));
        expect(node.position.x, 13.5);
        overlay.weight = 0;
        expect(node.position.x, 11);
        base.stop();
        expect(node.position.x, 7);
        second.stop();
        expect(node.position.x, 2);
        overlay.stop();
        expect(node.position.x, 2);
      }
    },
  );

  test(
    'rotation offsets use the chosen reference and compose in local play order',
    () {
      final node = Group()
        ..quaternion = Quat.axisAngle(const Vec3(0, 0, 1), .3);
      final rest = node.quaternion;
      final mixer = AnimationMixer(nodes: {'part': node});
      final reference = Quat.axisAngle(const Vec3(1, 0, 0), .4);
      AnimationClip rotation(Quat end) => AnimationClip(
        tracks: [
          QuaternionKeyframeTrack(
            target: 'part',
            times: [0, 1],
            values: [reference, reference * end],
          ),
        ],
      );
      final a = mixer.play(
        rotation(Quat.axisAngle(const Vec3(0, 1, 0), 1)),
        blendMode: AnimationBlendMode.additive,
        weight: .5,
      )..seek(const Duration(seconds: 1));
      final b = mixer.play(
        rotation(Quat.axisAngle(const Vec3(1, 0, 0), -.6)),
        blendMode: AnimationBlendMode.additive,
      )..seek(const Duration(seconds: 1));
      expectRotation(
        node.quaternion,
        rest *
            Quat.axisAngle(const Vec3(0, 1, 0), .5) *
            Quat.axisAngle(const Vec3(1, 0, 0), -.6),
      );
      a.stop();
      expectRotation(
        node.quaternion,
        rest * Quat.axisAngle(const Vec3(1, 0, 0), -.6),
      );
      b.stop();
      expectRotation(node.quaternion, rest);
      final antipodal = mixer.play(
        AnimationClip(
          tracks: [
            QuaternionKeyframeTrack(
              target: 'part',
              times: [0, 1],
              values: [
                reference,
                Quat(-reference.x, -reference.y, -reference.z, -reference.w),
              ],
            ),
          ],
        ),
        blendMode: AnimationBlendMode.additive,
      )..seek(const Duration(seconds: 1));
      expectRotation(node.quaternion, rest);
      antipodal.stop();
    },
  );

  test(
    'scale offsets use numeric differences and reject singular combined poses atomically',
    () async {
      final node = Group()..scale = const Vec3(2, 3, 4);
      final mixer = AnimationMixer(nodes: {'part': node});
      final clip = AnimationClip(
        tracks: [
          ...movement().tracks,
          VectorKeyframeTrack.scale(
            target: 'part',
            times: [0, 1],
            values: [const Vec3(3, 1, 2), const Vec3(1, 3, 4)],
          ),
        ],
      );
      final events = <AnimationEvent>[];
      final sub = mixer.events.listen(events.add);
      final action = mixer.play(
        clip,
        blendMode: AnimationBlendMode.additive,
        weight: .5,
        repetitions: 1,
      );
      action.seek(const Duration(seconds: 1));
      expect(node.scale, const Vec3(1, 4, 5));
      expect(node.position.x, 5);
      expect(() => action.weight = 1, throwsArgumentError);
      expect(action.weight, .5);
      expect(node.scale, const Vec3(1, 4, 5));
      action.seek(Duration.zero);
      action.weight = 1;
      expect(
        () => mixer.update(const Duration(seconds: 1)),
        throwsArgumentError,
      );
      expect(action.timeSeconds, 0);
      expect(action.isFinished, isFalse);
      expect(node.scale, const Vec3(2, 3, 4));
      expect(node.position, Vec3.zero);
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      await sub.cancel();
    },
  );

  test(
    'morph offsets preserve each primitive rest pose and independent instances',
    () {
      final a = morphMesh()..morphWeights = [.2, .4];
      final b = morphMesh()..morphWeights = [.6, .8];
      final other = morphMesh();
      final mixer = AnimationMixer(
        nodes: {'node': Group()},
        morphTargets: {
          'node': [a, b],
        },
      );
      final isolated = AnimationMixer(nodes: {'node': other});
      final clip = AnimationClip(
        tracks: [
          MorphWeightKeyframeTrack(
            target: 'node',
            times: [0, 1],
            values: [
              [.5, -.5],
              [1.5, .5],
            ],
          ),
        ],
      );
      final action = mixer.play(
        clip,
        blendMode: AnimationBlendMode.additive,
        weight: .5,
      );
      isolated.play(clip, blendMode: AnimationBlendMode.additive);
      expect(a.morphWeights, [.2, .4]);
      action.seek(const Duration(seconds: 1));
      expect(a.morphWeights, [.7, .9]);
      expect(b.morphWeights, [1.1, 1.3]);
      expect(other.morphWeights, [0, 0]);
      action.stop();
      expect(a.morphWeights, [.2, .4]);
      expect(b.morphWeights, [.6, .8]);
    },
  );

  test(
    'cubic reference poses sample the curve without rewriting shared keys',
    () {
      final node = Group()..position = const Vec3(10, 0, 0);
      final mixer = AnimationMixer(nodes: {'part': node});
      final track = VectorKeyframeTrack.position(
        target: 'part',
        times: [0, 1],
        values: [Vec3.zero, Vec3.one],
        interpolation: KeyframeInterpolation.cubicSpline,
        inTangents: [Vec3.zero, Vec3.zero],
        outTangents: [const Vec3(4, 0, 0), Vec3.zero],
      );
      final clip = AnimationClip(tracks: [track]);
      final action = mixer.play(
        clip,
        blendMode: AnimationBlendMode.additive,
        referenceTime: const Duration(milliseconds: 500),
      );
      action.seek(const Duration(milliseconds: 500));
      expect(node.position, const Vec3(10, 0, 0));
      action.seek(const Duration(seconds: 1));
      expect(node.position, const Vec3(10, .5, .5));
      expect(track.values, [Vec3.zero, Vec3.one]);
      expect(track.outTangents!.first.x, 4);
    },
  );

  test(
    'reference options and invalid sampled references fail before publication',
    () {
      final node = Group();
      final mixer = AnimationMixer(nodes: {'part': node});
      for (final time in [
        const Duration(microseconds: -1),
        const Duration(seconds: 2),
      ]) {
        expect(
          () => mixer.play(
            movement(),
            blendMode: AnimationBlendMode.additive,
            referenceTime: time,
          ),
          throwsArgumentError,
        );
      }
      expect(
        () => mixer.play(
          movement(),
          referenceTime: const Duration(milliseconds: 1),
        ),
        throwsArgumentError,
      );
      final bad = AnimationClip(
        tracks: [
          QuaternionKeyframeTrack(
            target: 'part',
            times: [0, 1],
            values: [Quat.identity, const Quat(0, 0, 0, -1)],
            interpolation: KeyframeInterpolation.cubicSpline,
            inTangents: [const Quat(0, 0, 0, 0), const Quat(0, 0, 0, 0)],
            outTangents: [const Quat(0, 0, 0, 0), const Quat(0, 0, 0, 0)],
          ),
        ],
      );
      expect(
        () => mixer.play(
          bad,
          blendMode: AnimationBlendMode.additive,
          referenceTime: const Duration(milliseconds: 500),
        ),
        throwsArgumentError,
      );
      expect(mixer.actions, isEmpty);
      expect(node.quaternion, Quat.identity);
    },
  );
}
