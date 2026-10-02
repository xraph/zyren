import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../../zyren/test/support/fakes.dart';

const end = Duration(seconds: 1);

class _ScalarTrack extends BlendableTimelineTrack {
  @override
  final Object3D target;
  final String channel;
  double value;
  _ScalarTrack(this.target, this.value, {this.channel = 'x'});
  @override
  Duration get end => const Duration(seconds: 1);
  @override
  _ScalarTrack snapshot() => _ScalarTrack(target, value, channel: channel);
  @override
  bool canBlendWith(BlendableTimelineTrack other) =>
      other is _ScalarTrack &&
      channel == other.channel &&
      identical(target, other.target);
  @override
  void Function() prepare(Duration time) =>
      () => target.position = Vec3(value, 0, 0);
  @override
  void Function() prepareBlend(
    List<TimelineBlendSample> absolute,
    List<TimelineBlendSample> additive,
  ) {
    if (additive.isNotEmpty) {
      throw StateError('This test track has no additive contract.');
    }
    var result = 0.0;
    for (final sample in absolute) {
      result += (sample.track as _ScalarTrack).value * sample.weight;
    }
    return () => target.position = Vec3(result, 0, 0);
  }
}

class _RetargetedSnapshot extends _ScalarTrack {
  _RetargetedSnapshot(super.target, super.value);
  @override
  _ScalarTrack snapshot() => _ScalarTrack(Group(), value);
}

void main() {
  test(
    'custom track snapshots freeze data and receive normalized samples',
    () async {
      final target = Group();
      final source = _ScalarTrack(target, 8);
      final clip = TimelineClip(duration: end, tracks: [source]);
      source.value = 99;
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: TimelineClip(duration: end, tracks: [_ScalarTrack(target, 0)]),
        layers: [
          TimelineLayer(clip: clip, weights: [ClipWeight(Duration.zero, .5)]),
        ],
      );
      final engine = await SceneEngine.create(
        scene: Scene()..add(target),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
      );
      addTearDown(engine.dispose);
      timeline.seek(end);
      expect(target.position.x, 4);
      timeline.createAction(clip, weight: 1);
      expect(target.position.x, 8);
    },
  );

  test('snapshots and same-target incompatible tracks reject before use', () {
    final target = Group();
    expect(
      () =>
          TimelineClip(duration: end, tracks: [_RetargetedSnapshot(target, 1)]),
      throwsArgumentError,
    );
    expect(
      () => SceneTimelinePlugin.mixed(
        duration: end,
        base: TimelineClip(duration: end, tracks: [_ScalarTrack(target, 0)]),
        layers: [
          TimelineLayer(
            clip: TimelineClip(
              duration: end,
              tracks: [_ScalarTrack(target, 2, channel: 'y')],
            ),
            weights: [ClipWeight(Duration.zero, 1)],
          ),
        ],
      ),
      throwsArgumentError,
    );
  });

  test(
    'failed custom preparation leaves other target poses unchanged',
    () async {
      final first = Group(), second = Group();
      final custom = TimelineClip(
        duration: end,
        tracks: [_ScalarTrack(second, 1)],
      );
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: TimelineClip(
          duration: end,
          tracks: [
            TransformTrack(first, [
              TransformKeyframe(Duration.zero),
              TransformKeyframe(end, position: const Vec3(4, 0, 0)),
            ]),
            ...custom.tracks,
          ],
        ),
        layers: [
          TimelineLayer(
            clip: custom,
            additive: true,
            weights: [ClipWeight(Duration.zero, 0), ClipWeight(end, 1)],
          ),
        ],
      );
      final engine = await SceneEngine.create(
        scene: Scene()
          ..add(first)
          ..add(second),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
      );
      addTearDown(engine.dispose);
      timeline.seek(Duration.zero);
      expect(() => timeline.seek(end), throwsStateError);
      expect(first.position, Vec3.zero);
      expect(second.position.x, 1);
      expect(timeline.position, Duration.zero);
    },
  );
}
