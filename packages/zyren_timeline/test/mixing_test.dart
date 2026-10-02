import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../../zyren/test/support/fakes.dart';

const end = Duration(seconds: 2);
Duration ms(int value) => Duration(milliseconds: value);

TimelineClip pose(
  Object3D target,
  double x, {
  Vec3 scale = Vec3.one,
  Quat rotation = Quat.identity,
  bool visible = true,
}) => TimelineClip(
  duration: end,
  tracks: [
    TransformTrack(target, [
      TransformKeyframe(
        Duration.zero,
        position: Vec3(x, 0, 0),
        scale: scale,
        rotation: rotation,
        visible: visible,
      ),
    ]),
  ],
);
TimelineLayer layer(TimelineClip clip, double weight) =>
    TimelineLayer(clip: clip, weights: [ClipWeight(Duration.zero, weight)]);

void main() {
  late Scene scene;
  late Mesh mesh;
  late PerspectiveCamera camera;
  var demands = 0;
  setUp(() {
    scene = Scene();
    mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    camera = PerspectiveCamera();
    demands = 0;
  });
  Future<SceneEngine> attach(SceneTimelinePlugin timeline) async {
    final engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => TestRenderer([]),
      plugins: [timeline],
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
    addTearDown(engine.dispose);
    return engine;
  }

  test('base remainder, overweight normalization and sparse targets', () async {
    final other = scene.add(Group());
    final base = TimelineClip(
      duration: end,
      tracks: [...pose(mesh, 2).tracks, ...pose(other, 7).tracks],
    );
    final first = layer(pose(mesh, 10), .25);
    var timeline = SceneTimelinePlugin.mixed(
      duration: end,
      base: base,
      layers: [first],
    );
    final engine = await attach(timeline);
    timeline.seek(ms(500));
    expect(mesh.position.x, 4);
    expect(other.position.x, 7);
    await engine.dispose();
    timeline = SceneTimelinePlugin.mixed(
      duration: end,
      base: base,
      layers: [layer(pose(mesh, 10), .75), layer(pose(mesh, 20), .75)],
    );
    await attach(timeline);
    timeline.seek(end);
    expect(mesh.position.x, 15);
    expect(other.position.x, 7);
  });

  test(
    'weight curves and clip offsets give deterministic absolute samples',
    () async {
      final animated = TimelineClip(
        duration: const Duration(seconds: 1),
        tracks: [
          TransformTrack(mesh, [
            TransformKeyframe(Duration.zero),
            TransformKeyframe(
              const Duration(seconds: 1),
              position: const Vec3(10, 0, 0),
            ),
          ]),
        ],
      );
      final lift = TimelineLayer(
        clip: animated,
        start: ms(500),
        weights: [
          ClipWeight(Duration.zero, 0),
          ClipWeight(ms(1000), 1),
          ClipWeight(end, 0),
        ],
      );
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: pose(mesh, 2),
        layers: [lift],
      );
      await attach(timeline);
      expect(lift.weightAt(ms(-1)), 0);
      expect(lift.weightAt(ms(500)), .5);
      expect(lift.weightAt(ms(3000)), 0);
      timeline.seek(ms(250));
      expect(mesh.position.x, 1.5);
      timeline.seek(ms(1000));
      expect(mesh.position.x, 5);
      timeline.seek(ms(1750));
      expect(mesh.position.x, 4);
      mesh.position = const Vec3(99, 99, 99);
      timeline.seek(ms(1000));
      expect(mesh.position, const Vec3(5, 0, 0));
      timeline.seek(end);
      expect(mesh.position.x, 2);
    },
  );

  test(
    'rotation signs align and visibility ties prefer the base then declaration order',
    () async {
      final turn = Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2);
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: pose(mesh, 0, visible: false),
        layers: [
          layer(
            pose(mesh, 0, rotation: Quat(-turn.x, -turn.y, -turn.z, -turn.w)),
            .5,
          ),
        ],
      );
      final engine = await attach(timeline);
      timeline.seek(end);
      expect(
        mesh.quaternion
            .rotate(const Vec3(1, 0, 0))
            .distanceTo(Vec3(math.sqrt(.5), 0, -math.sqrt(.5))),
        lessThan(1e-12),
      );
      expect(mesh.visible, isFalse);
      await engine.dispose();
      final tied = SceneTimelinePlugin.mixed(
        duration: end,
        base: pose(mesh, 0),
        layers: [
          layer(pose(mesh, 0, rotation: turn, visible: false), 1),
          layer(
            pose(mesh, 0, rotation: Quat(-turn.x, -turn.y, -turn.z, -turn.w)),
            1,
          ),
        ],
      );
      await attach(tied);
      tied.seek(end);
      expect(mesh.visible, isFalse);
      expect(
        mesh.quaternion
            .rotate(const Vec3(1, 0, 0))
            .distanceTo(const Vec3(0, 0, -1)),
        lessThan(1e-12),
      );
    },
  );

  test(
    'matching negative scale signs blend without losing reflection',
    () async {
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: pose(mesh, 0, scale: const Vec3(-1, 1, 2)),
        layers: [layer(pose(mesh, 0, scale: const Vec3(-3, 3, 4)), .5)],
      );
      await attach(timeline);
      timeline.seek(end);
      expect(mesh.scale, const Vec3(-2, 2, 3));
    },
  );

  test(
    'opposite scale signs reject the whole pose and pause without events',
    () async {
      final other = scene.add(Group());
      final base = TimelineClip(
        duration: end,
        tracks: [...pose(other, 10).tracks, ...pose(mesh, 0).tracks],
      );
      final mixed = TimelineLayer(
        clip: pose(mesh, 0, scale: const Vec3(-1, 1, 1)),
        weights: [ClipWeight(Duration.zero, 0), ClipWeight(end, 1)],
      );
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: base,
        layers: [mixed],
        markers: [TimelineMarker(ms(500), id: 'half')],
      );
      final engine = await attach(timeline);
      final events = <TimelineEvent>[];
      final subscription = timeline.events.listen(events.add);
      addTearDown(subscription.cancel);
      timeline.play();
      await engine.render(elapsed: Duration.zero, width: 8, height: 8);
      other.position = const Vec3(99, 0, 0);
      await expectLater(
        engine.render(
          elapsed: ms(1000),
          time: FrameTime(elapsed: ms(1000), delta: ms(1000)),
          width: 8,
          height: 8,
        ),
        throwsArgumentError,
      );
      await Future<void>.delayed(Duration.zero);
      expect(other.position.x, 99);
      expect(mesh.scale, Vec3.one);
      expect(timeline.position, Duration.zero);
      expect(timeline.isPlaying, isFalse);
      expect(demands, 0);
      expect(events, isEmpty);
      timeline.seek(end);
      expect(mesh.scale.x, -1);
    },
  );

  test('camera blends validate before any object edit', () async {
    TimelineClip cameraPose(Vec3 position, {Vec3 up = const Vec3(0, 1, 0)}) =>
        TimelineClip(
          duration: end,
          tracks: [
            CameraTrack(camera, [
              CameraKeyframe(
                Duration.zero,
                position: position,
                target: Vec3.zero,
                up: up,
              ),
            ]),
          ],
        );
    final base = TimelineClip(
      duration: end,
      tracks: [
        ...pose(mesh, 10).tracks,
        ...cameraPose(const Vec3(0, 0, 5)).tracks,
      ],
    );
    var timeline = SceneTimelinePlugin.mixed(
      duration: end,
      base: base,
      layers: [layer(cameraPose(const Vec3(2, 0, 5)), .5)],
    );
    final engine = await attach(timeline);
    timeline.seek(end);
    expect(camera.position, const Vec3(1, 0, 5));
    await engine.dispose();
    mesh.position = Vec3.zero;
    timeline = SceneTimelinePlugin.mixed(
      duration: end,
      base: base,
      layers: [layer(cameraPose(const Vec3(0, 0, -5)), .5)],
    );
    await attach(timeline);
    expect(() => timeline.seek(end), throwsArgumentError);
    expect(mesh.position, Vec3.zero);
    expect(camera.position, const Vec3(1, 0, 5));
  });

  test(
    'zero-weight invalid camera samples are skipped including the base',
    () async {
      final invalid = TimelineClip(
        duration: end,
        tracks: [
          CameraTrack(camera, [
            CameraKeyframe(
              Duration.zero,
              position: const Vec3(0, 0, 5),
              target: Vec3.zero,
            ),
            CameraKeyframe(
              end,
              position: const Vec3(0, 0, -5),
              target: Vec3.zero,
            ),
          ]),
        ],
      );
      final valid = TimelineClip(
        duration: end,
        tracks: [
          CameraTrack(camera, [
            CameraKeyframe(
              Duration.zero,
              position: const Vec3(2, 0, 5),
              target: Vec3.zero,
            ),
          ]),
        ],
      );
      var timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: valid,
        layers: [layer(invalid, 0)],
      );
      final engine = await attach(timeline);
      timeline.seek(ms(1000));
      expect(camera.position, const Vec3(2, 0, 5));
      await engine.dispose();
      timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: invalid,
        layers: [layer(valid, 1)],
      );
      await attach(timeline);
      timeline.seek(ms(1000));
      expect(camera.position, const Vec3(2, 0, 5));
    },
  );

  test(
    'clips and curves copy inputs and reject malformed or mismatched tracks',
    () {
      final tracks = pose(mesh, 0).tracks.toList();
      final clip = TimelineClip(duration: end, tracks: tracks);
      tracks.clear();
      expect(clip.tracks, hasLength(1));
      expect(() => clip.tracks.clear(), throwsUnsupportedError);
      final weights = [ClipWeight(Duration.zero, .5)];
      final mixed = TimelineLayer(clip: clip, weights: weights);
      weights.clear();
      expect(mixed.weightAt(end), .5);
      expect(() => mixed.weights.clear(), throwsUnsupportedError);
      for (final invalid in [-.1, 1.1, double.nan, double.infinity]) {
        expect(() => ClipWeight(Duration.zero, invalid), throwsArgumentError);
      }
      expect(() => ClipWeight(ms(-1), 0), throwsArgumentError);
      expect(() => TimelineLayer(clip: clip, weights: []), throwsArgumentError);
      expect(
        () => TimelineLayer(clip: clip, start: ms(-1), weights: mixed.weights),
        throwsArgumentError,
      );
      expect(
        () => TimelineLayer(
          clip: clip,
          weights: [ClipWeight(end, 0), ClipWeight(end, 1)],
        ),
        throwsArgumentError,
      );
      expect(
        () => TimelineClip(duration: Duration.zero, tracks: []),
        throwsArgumentError,
      );
      expect(
        () => TimelineClip(
          duration: end,
          tracks: [...clip.tracks, ...clip.tracks],
        ),
        throwsArgumentError,
      );
      expect(
        () => TimelineClip(
          duration: ms(1),
          tracks: [
            TransformTrack(mesh, [TransformKeyframe(end)]),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => TimelineClip(duration: end, tracks: [_CustomTrack(mesh)]),
        throwsArgumentError,
      );
      expect(
        () => SceneTimelinePlugin.mixed(
          duration: end,
          base: clip,
          layers: [layer(pose(Group(), 0), 1)],
        ),
        throwsArgumentError,
      );
      expect(
        () => SceneTimelinePlugin.mixed(
          duration: ms(1),
          base: clip,
          layers: [
            TimelineLayer(clip: clip, weights: [ClipWeight(end, 1)]),
          ],
        ),
        throwsArgumentError,
      );
      expect(
        () => SceneTimelinePlugin.mixed(
          duration: end,
          base: pose(camera, 0),
          layers: [
            layer(
              TimelineClip(
                duration: end,
                tracks: [
                  CameraTrack(camera, [
                    CameraKeyframe(
                      Duration.zero,
                      position: const Vec3(0, 0, 5),
                      target: Vec3.zero,
                    ),
                  ]),
                ],
              ),
              1,
            ),
          ],
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'mixing retains loop markers, demand ownership and silent seek',
    () async {
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: pose(mesh, 0),
        layers: [layer(pose(mesh, 10), .5)],
        loop: true,
        markers: [
          TimelineMarker(Duration.zero, id: 'start'),
          TimelineMarker(end, id: 'end'),
        ],
      );
      final events = <TimelineEvent>[];
      final subscription = timeline.events.listen(events.add);
      addTearDown(subscription.cancel);
      final engine = await attach(timeline);
      timeline.seek(ms(500));
      await Future<void>.delayed(Duration.zero);
      expect(events, isEmpty);
      timeline.seek(Duration.zero);
      timeline.play();
      timeline.play();
      expect(demands, 1);
      await engine.render(elapsed: Duration.zero, width: 8, height: 8);
      await engine.render(
        elapsed: end,
        time: FrameTime(elapsed: end, delta: end),
        width: 8,
        height: 8,
      );
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => (e.marker.id, e.loopIndex)), [
        ('start', 0),
        ('end', 0),
        ('start', 1),
      ]);
      expect(mesh.position.x, 5);
      await engine.dispose();
      expect(demands, 0);
      expect(mesh.position.x, 5);
      expect(() => timeline.seek(end), throwsStateError);
    },
  );

  test(
    'base clip time clamps and layer inputs freeze at construction',
    () async {
      final base = TimelineClip(
        duration: ms(500),
        tracks: [
          TransformTrack(mesh, [
            TransformKeyframe(Duration.zero),
            TransformKeyframe(ms(500), position: const Vec3(8, 0, 0)),
          ]),
        ],
      );
      final layers = [
        TimelineLayer(
          clip: pose(mesh, 16),
          weights: [ClipWeight(ms(500), .25), ClipWeight(ms(1000), .5)],
        ),
      ];
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: base,
        layers: layers,
      );
      layers.clear();
      await attach(timeline);
      timeline.seek(Duration.zero);
      expect(mesh.position.x, 4);
      timeline.seek(end);
      expect(mesh.position.x, 12);
    },
  );

  test(
    'opposing camera up vectors reject the blend before applying a pose',
    () async {
      TimelineClip view(Vec3 up) => TimelineClip(
        duration: end,
        tracks: [
          CameraTrack(camera, [
            CameraKeyframe(
              Duration.zero,
              position: const Vec3(0, 0, 5),
              target: Vec3.zero,
              up: up,
            ),
          ]),
        ],
      );
      final timeline = SceneTimelinePlugin.mixed(
        duration: end,
        base: view(const Vec3(0, 2, 0)),
        layers: [layer(view(const Vec3(0, -8, 0)), .5)],
      );
      await attach(timeline);
      final initial = camera.position;
      expect(() => timeline.seek(end), throwsArgumentError);
      expect(camera.position, initial);
      expect(camera.up, const Vec3(0, 1, 0));
    },
  );

  test('mixed targets retain scene and parent ownership checks', () async {
    final timeline = SceneTimelinePlugin.mixed(
      duration: end,
      base: pose(mesh, 0),
      layers: [layer(pose(mesh, 10), .5)],
    );
    await attach(timeline);
    timeline.play();
    scene.add(Group()).add(mesh);
    expect(() => timeline.seek(end), throwsStateError);
    expect(mesh.position.x, 5);
    expect(demands, 0);
  });
}

class _CustomTrack extends TimelineTrack {
  @override
  final Object3D target;
  _CustomTrack(this.target);
  @override
  Duration get end => Duration.zero;
  @override
  void Function() prepare(Duration time) => () {};
}
