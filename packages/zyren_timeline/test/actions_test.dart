import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  late Scene scene;
  late Mesh mesh;
  late SceneTimelinePlugin timeline;
  late SceneEngine engine;
  var demands = 0;
  const length = Duration(seconds: 1);
  TimelineClip clip(double x, {double scale = 1}) => TimelineClip(
    duration: length,
    tracks: [
      TransformTrack(mesh, [
        TransformKeyframe(
          Duration.zero,
          position: Vec3(x, 0, 0),
          scale: Vec3(scale, scale, scale),
        ),
      ]),
    ],
  );
  setUp(() async {
    demands = 0;
    scene = Scene();
    mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    timeline = SceneTimelinePlugin.mixed(duration: length, base: clip(0));
    engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [timeline],
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
  });
  tearDown(() async => engine.dispose());
  Future<void> tick(int ms) =>
      engine.render(elapsed: Duration(milliseconds: ms), width: 8, height: 8);

  test(
    'independent clocks survive main seeks and release demand at completion',
    () async {
      final action = timeline.createAction(clip(10), weight: 1)..play();
      await tick(0);
      await tick(100);
      expect(action.position, const Duration(milliseconds: 100));
      expect(timeline.position, Duration.zero);
      timeline.seek(const Duration(milliseconds: 700));
      expect(action.position, const Duration(milliseconds: 100));
      for (var ms = 200; ms <= 1100; ms += 100) {
        await tick(ms);
      }
      expect(action.position, length);
      expect(action.isPlaying, isFalse);
      expect(demands, 0);
      action.play();
      expect(action.position, Duration.zero);
      action.pause();
      expect(demands, 0);
    },
  );

  test(
    'crossfade interruption starts at current weights and normalizes overlap',
    () async {
      final a = timeline.createAction(clip(10), weight: 1)..play();
      final b = timeline.createAction(clip(20));
      a.crossFadeTo(b, length);
      await tick(0);
      await tick(100);
      expect(mesh.position.x, closeTo(11, 1e-9));
      b.crossFadeTo(a, length);
      await tick(200);
      expect(mesh.position.x, closeTo(10.9, 1e-9));
      b.fadeTo(1, Duration.zero);
      a.fadeTo(1, Duration.zero);
      expect(mesh.position.x, closeTo(15, 1e-9));
      a.dispose();
      expect(mesh.position.x, 20);
      expect(() => a.play(), throwsStateError);
    },
  );

  test('failed runtime blend keeps pose and action clocks atomic', () async {
    final a = timeline.createAction(clip(10), weight: 1)..play();
    final bad = timeline.createAction(clip(20, scale: -1));
    bad.fadeTo(1, length);
    await tick(0);
    await expectLater(tick(100), throwsArgumentError);
    expect(mesh.position.x, 10);
    expect(a.position, Duration.zero);
    expect(bad.weight, 0);
    expect(demands, 0);
  });

  test('detach invalidates handles and releases independent demand', () async {
    final action = timeline.createAction(clip(10))..play();
    expect(demands, 1);
    await engine.dispose();
    expect(demands, 0);
    expect(() => action.play(), throwsStateError);
  });
  test(
    'reverse action starts at end and looping retains reverse overshoot',
    () async {
      final action = timeline.createAction(clip(10), reverse: true)..play();
      expect(action.position, length);
      await tick(0);
      await tick(100);
      expect(action.position, const Duration(milliseconds: 900));
      action.seek(const Duration(milliseconds: 50));
      action.loop = true;
      await tick(200);
      expect(action.position, const Duration(milliseconds: 950));
      action.loop = false;
      action.seek(const Duration(milliseconds: 50));
      await tick(300);
      expect(action.position, Duration.zero);
      expect(action.isPlaying, isFalse);
      expect(demands, 0);
    },
  );

  test('authored layer looping and reverse time are deterministic', () {
    final layer = TimelineLayer(
      clip: clip(10),
      start: const Duration(milliseconds: 100),
      loop: true,
      reverse: true,
      weights: [ClipWeight(Duration.zero, 1)],
    );
    expect(layer.localTimeAt(Duration.zero), length);
    expect(
      layer.localTimeAt(const Duration(milliseconds: 350)),
      const Duration(milliseconds: 750),
    );
    expect(layer.localTimeAt(const Duration(milliseconds: 1100)), length);
    expect(
      layer.localTimeAt(const Duration(milliseconds: 1350)),
      const Duration(milliseconds: 750),
    );
  });

  test(
    'additive action applies reference deltas without consuming base weight',
    () {
      final delta = TimelineClip(
        duration: length,
        tracks: [
          TransformTrack(mesh, [
            TransformKeyframe(Duration.zero, position: const Vec3(3, 0, 0)),
            TransformKeyframe(
              length,
              position: const Vec3(7, 0, 0),
              scale: const Vec3(3, 3, 3),
            ),
          ]),
        ],
      );
      timeline.createAction(clip(10), weight: 1);
      final action = timeline.createAction(delta, weight: .5, additive: true);
      action.seek(length);
      expect(mesh.position.x, 12);
      expect(mesh.scale, const Vec3(2, 2, 2));
      timeline.seek(const Duration(milliseconds: 500));
      expect(mesh.position.x, 12);
      action.seek(Duration.zero);
      expect(mesh.position.x, 10);
      expect(mesh.scale, Vec3.one);
    },
  );
  test(
    'reverse main clock emits endpoint markers, ordered ties and loop edges',
    () async {
      await engine.dispose();
      timeline = SceneTimelinePlugin.mixed(
        duration: length,
        base: clip(0),
        reverse: true,
        loop: true,
        markers: [
          TimelineMarker(Duration.zero, id: 'zero'),
          TimelineMarker(const Duration(milliseconds: 900), id: 'a'),
          TimelineMarker(const Duration(milliseconds: 900), id: 'b'),
          TimelineMarker(length, id: 'end'),
        ],
      );
      engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
      );
      final events = <TimelineEvent>[];
      final subscription = timeline.events.listen(events.add);
      timeline.play();
      await tick(0);
      for (var ms = 100; ms <= 1000; ms += 100) {
        await tick(ms);
      }
      await Future<void>.delayed(Duration.zero);
      expect(events.map((e) => e.marker.id), ['end', 'a', 'b', 'zero', 'end']);
      expect(events.last.loopIndex, 1);
      expect(timeline.position, length);
      timeline.loop = false;
      for (var ms = 1100; ms <= 2000; ms += 100) {
        await tick(ms);
      }
      expect(timeline.position, Duration.zero);
      expect(timeline.isPlaying, isFalse);
      timeline.play();
      expect(timeline.position, length);
      await subscription.cancel();
    },
  );

  test(
    'additive rotation uses local reference and deterministic layer order',
    () {
      final rotation = TimelineClip(
        duration: length,
        tracks: [
          TransformTrack(mesh, [
            TransformKeyframe(
              Duration.zero,
              rotation: Quat.axisAngle(const Vec3(0, 1, 0), math.pi / 2),
            ),
            TransformKeyframe(
              length,
              rotation: Quat.axisAngle(const Vec3(0, 1, 0), math.pi),
            ),
          ]),
        ],
      );
      final action = timeline.createAction(
        rotation,
        additive: true,
        weight: .5,
      );
      action.seek(length);
      expect(
        mesh.quaternion.rotate(const Vec3(1, 0, 0)).x,
        closeTo(math.sqrt(.5), 1e-9),
      );
      expect(
        mesh.quaternion.rotate(const Vec3(1, 0, 0)).z,
        closeTo(-math.sqrt(.5), 1e-9),
      );
      action.seek(Duration.zero);
      expect(
        mesh.quaternion
            .rotate(const Vec3(1, 0, 0))
            .distanceTo(const Vec3(1, 0, 0)),
        lessThan(1e-9),
      );
      expect(
        () => timeline.createAction(
          rotation,
          additive: true,
          referenceTime: const Duration(seconds: 2),
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'authored looping reverse layer samples poses through silent seeks',
    () async {
      await engine.dispose();
      final moving = TimelineClip(
        duration: length,
        tracks: [
          TransformTrack(mesh, [
            TransformKeyframe(Duration.zero),
            TransformKeyframe(length, position: const Vec3(10, 0, 0)),
          ]),
        ],
      );
      timeline = SceneTimelinePlugin.mixed(
        duration: const Duration(seconds: 3),
        base: clip(0),
        layers: [
          TimelineLayer(
            clip: moving,
            loop: true,
            reverse: true,
            weights: [ClipWeight(Duration.zero, 1)],
          ),
        ],
      );
      engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
      );
      timeline.seek(const Duration(milliseconds: 1250));
      expect(mesh.position.x, 7.5);
      timeline.seek(const Duration(milliseconds: 250));
      expect(mesh.position.x, 7.5);
      timeline.seek(length);
      expect(mesh.position.x, 10);
    },
  );
  test('reverse looping actions retain the end on exact boundaries', () async {
    final action = timeline.createAction(clip(10), reverse: true, loop: true)
      ..play();
    await tick(0);
    for (var ms = 100; ms <= 1000; ms += 100) {
      await tick(ms);
    }
    expect(action.position, length);
    expect(action.isPlaying, isTrue);
    action.pause();
    expect(demands, 0);
  });

  test(
    'additive camera deltas validate atomically with object edits',
    () async {
      await engine.dispose();
      final camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
      final base = TimelineClip(
        duration: length,
        tracks: [
          TransformTrack(mesh, [TransformKeyframe(Duration.zero)]),
          CameraTrack(camera, [
            CameraKeyframe(
              Duration.zero,
              position: const Vec3(0, 0, 5),
              target: Vec3.zero,
            ),
          ]),
        ],
      );
      timeline = SceneTimelinePlugin.mixed(duration: length, base: base);
      engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
      );
      final delta = TimelineClip(
        duration: length,
        tracks: [
          TransformTrack(mesh, [
            TransformKeyframe(Duration.zero),
            TransformKeyframe(length, position: const Vec3(10, 0, 0)),
          ]),
          CameraTrack(camera, [
            CameraKeyframe(
              Duration.zero,
              position: const Vec3(0, 0, 1),
              target: Vec3.zero,
            ),
            CameraKeyframe(
              length,
              position: const Vec3(0, 0, -4),
              target: Vec3.zero,
            ),
          ]),
        ],
      );
      final action = timeline.createAction(delta, additive: true, weight: 1);
      expect(() => action.seek(length), throwsArgumentError);
      expect(mesh.position, Vec3.zero);
      expect(camera.position, const Vec3(0, 0, 5));
      expect(action.position, Duration.zero);
    },
  );
  test(
    'reverse event overflow rolls back independent clocks and pose',
    () async {
      await engine.dispose();
      timeline = SceneTimelinePlugin.mixed(
        duration: length,
        base: clip(0),
        reverse: true,
        loop: true,
        maxEventsPerAdvance: 2,
        markers: [
          TimelineMarker(Duration.zero, id: 'zero'),
          TimelineMarker(length, id: 'end'),
        ],
      );
      engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [timeline],
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      final action = timeline.createAction(clip(10), weight: 1)..play();
      timeline.play();
      await tick(0);
      await expectLater(
        engine.render(
          elapsed: const Duration(seconds: 5),
          time: FrameTime(delta: const Duration(seconds: 5)),
          width: 8,
          height: 8,
        ),
        throwsStateError,
      );
      expect(timeline.position, length);
      expect(action.position, Duration.zero);
      expect(mesh.position.x, 10);
      expect(action.isPlaying, isFalse);
      expect(timeline.isPlaying, isFalse);
      expect(demands, 0);
    },
  );
}
