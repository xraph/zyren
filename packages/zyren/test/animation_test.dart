import 'dart:math' as math;
import 'dart:collection';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';

AnimationClip movement({double end = 10, double duration = 1}) => AnimationClip(
  name: 'move',
  tracks: [
    VectorKeyframeTrack.position(
      target: 'part',
      times: [0, duration],
      values: [Vec3.zero, Vec3(end, 0, 0)],
    ),
  ],
);

void main() {
  test('short arcs and weighted rotations retain spherical interpolation', () {
    final track = QuaternionKeyframeTrack(
      target: 'part',
      times: [0, 1],
      values: [Quat.identity, Quat.axisAngle(const Vec3(0, 0, 1), .04)],
    );
    final v = track.sample(.25).rotate(const Vec3(1, 0, 0));
    expect(v.y, closeTo(math.sin(.01), 1e-12));
    final node = Group();
    final mixer = AnimationMixer(nodes: {'part': node});
    expect(mixer.id, isNot(AnimationMixer(nodes: {}).id));
    mixer.play(
      AnimationClip(
        tracks: [
          QuaternionKeyframeTrack(
            target: 'part',
            times: [0],
            values: [Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2)],
          ),
        ],
      ),
      weight: .25,
    );
    expect(
      node.quaternion.rotate(const Vec3(1, 0, 0)).y,
      closeTo(math.sin(math.pi / 8), 1e-12),
    );
  });
  test(
    'step, linear and cubic tracks retain endpoints and segment duration',
    () {
      final values = [Vec3.zero, const Vec3(8, 0, 0)];
      final times = [2.0, 4.0];
      final linear = VectorKeyframeTrack.position(
        target: 'part',
        times: times,
        values: values,
      );
      final step = VectorKeyframeTrack.position(
        target: 'part',
        times: times,
        values: values,
        interpolation: KeyframeInterpolation.step,
      );
      final cubic = VectorKeyframeTrack.position(
        target: 'part',
        times: times,
        values: values,
        interpolation: KeyframeInterpolation.cubicSpline,
        inTangents: [Vec3.zero, Vec3.zero],
        outTangents: [const Vec3(4, 0, 0), Vec3.zero],
      );
      times[0] = 99;
      values[0] = Vec3.one;
      expect(linear.sample(0), Vec3.zero);
      expect(linear.sample(3), const Vec3(4, 0, 0));
      expect(linear.sample(8), const Vec3(8, 0, 0));
      expect(step.sample(3.999), Vec3.zero);
      expect(step.sample(4), const Vec3(8, 0, 0));
      expect(cubic.sample(3), const Vec3(5, 0, 0));
      expect(() => linear.times.add(6), throwsUnsupportedError);
    },
  );
  test(
    'quaternion linear takes the short arc; cubic retains authored signs',
    () {
      final q = Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2);
      final linear = QuaternionKeyframeTrack(
        target: 'part',
        times: [0, 1],
        values: [Quat.identity, Quat(-q.x, -q.y, -q.z, -q.w)],
      );
      final halfway = linear.sample(.5).rotate(const Vec3(1, 0, 0));
      expect(halfway.x, closeTo(math.sqrt(.5), 1e-12));
      expect(halfway.y, closeTo(math.sqrt(.5), 1e-12));
      final cubic = QuaternionKeyframeTrack(
        target: 'part',
        times: [0, 2],
        values: [Quat.identity, const Quat(0, 0, 1, 0)],
        interpolation: KeyframeInterpolation.cubicSpline,
        inTangents: [const Quat(0, 0, 0, 0), const Quat(0, 0, 0, 0)],
        outTangents: [const Quat(0, 0, 2, 0), const Quat(0, 0, 0, 0)],
      );
      final sample = cubic.sample(1);
      expect(sample.z, closeTo(2 / math.sqrt(5), 1e-12));
      expect(sample.w, closeTo(1 / math.sqrt(5), 1e-12));
    },
  );
  test('tracks reject malformed timelines and duplicate channels', () {
    for (final times in [
      [0.0, 0.0],
      [1.0, 0.0],
      [-1.0, 1.0],
      [0.0, double.nan],
    ]) {
      expect(
        () => VectorKeyframeTrack.position(
          target: 'part',
          times: times,
          values: [Vec3.zero, Vec3.one],
        ),
        throwsArgumentError,
      );
    }
    expect(
      () => QuaternionKeyframeTrack(
        target: 'part',
        times: [0],
        values: [const Quat(0, 0, 0, 0)],
      ),
      throwsArgumentError,
    );
    expect(
      () => VectorKeyframeTrack.position(
        target: 'part',
        times: [0],
        values: [Vec3.zero],
        interpolation: KeyframeInterpolation.cubicSpline,
      ),
      throwsArgumentError,
    );
    expect(
      () => AnimationClip(tracks: [...movement().tracks, ...movement().tracks]),
      throwsArgumentError,
    );
  });
  test(
    'two mixers share a clip while poses and playheads remain independent',
    () {
      final a = Group(), b = Group();
      final clip = movement();
      final first = AnimationMixer(nodes: {'part': a}),
          second = AnimationMixer(nodes: {'part': b});
      final action = first.play(clip);
      second.play(clip);
      action.seek(const Duration(milliseconds: 500));
      expect(a.position.x, 5);
      expect(b.position.x, 0);
      action.pause();
      first.update(const Duration(seconds: 2));
      expect(a.position.x, 5);
      action.resume();
      first.update(const Duration(milliseconds: 250));
      expect(a.position.x, 7.5);
      action.stop();
      expect(a.position, Vec3.zero);
      expect(first.actions, isEmpty);
      expect(() => action.seek(Duration.zero), throwsStateError);
    },
  );
  test(
    'repeat, ping-pong and negative once playback have exact boundaries',
    () {
      final node = Group(), mixer = AnimationMixer(nodes: {'part': Group()});
      final reverse = mixer.play(
        movement(),
        loop: AnimationLoop.once,
        speed: -1,
      );
      expect(reverse.timeSeconds, 1);
      mixer.update(const Duration(milliseconds: 250));
      expect(reverse.timeSeconds, .75);
      mixer.update(const Duration(seconds: 2));
      expect(reverse.timeSeconds, 0);
      expect(reverse.isFinished, isTrue);
      final pingMixer = AnimationMixer(nodes: {'part': node});
      final ping = pingMixer.play(movement(), loop: AnimationLoop.pingPong);
      pingMixer.update(const Duration(seconds: 1));
      expect(node.position.x, 10);
      pingMixer.update(const Duration(milliseconds: 250));
      expect(node.position.x, 7.5);
      ping.speed = -1;
      pingMixer.update(const Duration(milliseconds: 250));
      expect(node.position.x, 10);
      ping.loop = AnimationLoop.repeat;
      ping.seek(Duration.zero);
      ping.speed = 1;
      pingMixer.update(const Duration(seconds: 5));
      expect(node.position.x, 0);
    },
  );
  test(
    'weighted actions preserve rest pose and normalize excess total weight',
    () {
      final node = Group()..position = const Vec3(2, 0, 0);
      final mixer = AnimationMixer(nodes: {'part': node});
      final a = mixer.play(movement(), weight: .25)
        ..seek(const Duration(seconds: 1));
      expect(node.position.x, 4);
      final b = mixer.play(movement(end: 20), weight: .25)
        ..seek(const Duration(seconds: 1));
      expect(node.position.x, 8.5);
      a.weight = 1;
      b.weight = 1;
      expect(node.position.x, 15);
      b.stop();
      expect(node.position.x, 10);
      a.stop();
      expect(node.position.x, 2);
    },
  );
  test('invalid sampled poses leave all nodes and action times unchanged', () {
    final first = Group(), second = Group();
    final mixer = AnimationMixer(nodes: {'part': first, 'scale': second});
    final clip = AnimationClip(
      tracks: [
        ...movement().tracks,
        VectorKeyframeTrack.scale(
          target: 'scale',
          times: [0, 1],
          values: [Vec3.one, const Vec3(-1, 1, 1)],
        ),
      ],
    );
    final action = mixer.play(clip);
    expect(
      () => action.seek(const Duration(milliseconds: 500)),
      throwsArgumentError,
    );
    expect(action.timeSeconds, 0);
    expect(first.position, Vec3.zero);
    expect(second.scale, Vec3.one);
    expect(
      () => mixer.update(const Duration(milliseconds: 500)),
      throwsArgumentError,
    );
    expect(action.timeSeconds, 0);
    expect(first.position, Vec3.zero);
  });
  test(
    'zero-duration clips finish immediately and retain the sampled pose',
    () {
      final node = Group(), mixer = AnimationMixer(nodes: {'part': Group()});
      final zero = AnimationClip(
        tracks: [
          VectorKeyframeTrack.position(
            target: 'part',
            times: [0],
            values: [Vec3.one],
          ),
        ],
      );
      final action = mixer.play(zero);
      expect(action.isFinished, isTrue);
      expect(mixer.isAdvancing, isFalse);
      mixer.update(const Duration(days: 1));
      expect(action.timeSeconds, 0);
      final separate = AnimationMixer(nodes: {'part': node});
      separate.play(zero);
      expect(node.position, Vec3.one);
      separate.stopAll();
      expect(node.position, Vec3.zero);
    },
  );
  test(
    'cubic quaternion signs are retained and invalid intermediate rotations fail atomically',
    () {
      final node = Group();
      final mixer = AnimationMixer(nodes: {'part': node});
      final track = QuaternionKeyframeTrack(
        target: 'part',
        times: [0, 1],
        values: [Quat.identity, const Quat(0, 0, 0, -1)],
        interpolation: KeyframeInterpolation.cubicSpline,
        inTangents: [const Quat(0, 0, 0, 0), const Quat(0, 0, 0, 0)],
        outTangents: [const Quat(0, 0, 0, 0), const Quat(0, 0, 0, 0)],
      );
      final action = mixer.play(
        AnimationClip(tracks: [...movement().tracks, track]),
      );
      expect(
        () => action.seek(const Duration(milliseconds: 500)),
        throwsArgumentError,
      );
      expect(node.position, Vec3.zero);
      expect(node.quaternion, Quat.identity);
      expect(action.timeSeconds, 0);
    },
  );
  test(
    'constructor budgets reject oversized arrays before copying their data',
    () {
      expect(
        () => VectorKeyframeTrack.position(
          target: 'part',
          times: _UntouchableList<double>(1000001),
          values: _UntouchableList<Vec3>(1000001),
        ),
        throwsArgumentError,
      );
      expect(
        () => QuaternionKeyframeTrack(
          target: 'part',
          times: [0],
          values: _UntouchableList<Quat>(1000001),
        ),
        throwsArgumentError,
      );
      expect(
        () => AnimationClip(tracks: _UntouchableList<KeyframeTrack>(4097)),
        throwsArgumentError,
      );
    },
  );
  test('stopping actions frees admission and captures a fresh rest pose', () {
    final node = Group(), mixer = AnimationMixer(nodes: {'part': Group()});
    final empty = AnimationClip(tracks: []);
    for (var i = 0; i < 256; i++) {
      mixer.play(empty);
    }
    expect(() => mixer.play(empty), throwsStateError);
    mixer.stopAll();
    expect(mixer.play(empty).isFinished, isTrue);
    final reusable = AnimationMixer(nodes: {'part': node});
    reusable.play(movement()).stop();
    node.position = const Vec3(20, 0, 0);
    final action = reusable.play(movement(), weight: .5);
    expect(node.position.x, 10);
    action.stop();
    expect(node.position.x, 20);
  });
  test(
    'missing bindings and invalid weights are rejected without scene edits',
    () {
      final node = Group(), mixer = AnimationMixer(nodes: {'wrong': Group()});
      expect(() => mixer.play(movement()), throwsArgumentError);
      expect(mixer.actions, isEmpty);
      final valid = AnimationMixer(nodes: {'part': node});
      final action = valid.play(movement());
      expect(() => action.weight = double.nan, throwsArgumentError);
      expect(() => action.speed = double.infinity, throwsArgumentError);
      expect(
        () => valid.update(const Duration(seconds: -1)),
        throwsArgumentError,
      );
      expect(action.weight, 1);
      expect(action.speed, 1);
      expect(node.position, Vec3.zero);
    },
  );
}

class _UntouchableList<T> extends ListBase<T> {
  final int _length;
  _UntouchableList(this._length);
  @override
  int get length => _length;
  @override
  set length(int value) => throw StateError('No writes.');
  @override
  T operator [](int index) =>
      throw StateError('Budget must fail before reading data.');
  @override
  void operator []=(int index, T value) => throw StateError('No writes.');
}
