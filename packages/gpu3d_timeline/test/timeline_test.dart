import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_timeline/gpu3d_timeline.dart';
import 'package:test/test.dart';
import '../../gpu3d/test/support/fakes.dart';

const end = Duration(seconds: 1);
void main() {
  late Scene scene;
  late Mesh mesh;
  late PerspectiveCamera camera;
  late SceneTimelinePlugin timeline;
  late SceneEngine engine;
  var demands = 0;
  setUp(() async {
    demands = 0;
    scene = Scene();
    mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial()));
    camera = PerspectiveCamera();
    timeline = SceneTimelinePlugin(
      duration: end,
      tracks: [
        TransformTrack(mesh, [
          TransformKeyframe(Duration.zero),
          TransformKeyframe(
            end,
            position: const Vec3(10, 2, 0),
            rotation: Quat.axisAngle(const Vec3(0, 1, 0), math.pi),
            scale: const Vec3(3, 3, 3),
            visible: false,
          ),
        ]),
        CameraTrack(camera, [
          CameraKeyframe(
            Duration.zero,
            position: const Vec3(0, 0, 5),
            target: Vec3.zero,
          ),
          CameraKeyframe(
            end,
            position: const Vec3(2, 0, 5),
            target: const Vec3(2, 0, 0),
          ),
        ]),
      ],
    );
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => TestRenderer([]),
      plugins: [timeline],
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
  });
  tearDown(() async => engine.dispose());

  test(
    'seek evaluates absolute poses, shortest rotation and step visibility',
    () {
      timeline.seek(const Duration(milliseconds: 500));
      expect(mesh.position, const Vec3(5, 1, 0));
      expect(mesh.scale, const Vec3(2, 2, 2));
      expect(
        mesh.quaternion
            .rotate(const Vec3(1, 0, 0))
            .distanceTo(const Vec3(0, 0, -1)),
        lessThan(1e-10),
      );
      expect(mesh.visible, isTrue);
      expect(camera.position, const Vec3(1, 0, 5));
      expect(camera.target, const Vec3(1, 0, 0));
      timeline.seek(end);
      expect(mesh.visible, isFalse);
      timeline.seek(Duration.zero);
      timeline.seek(const Duration(milliseconds: 500));
      expect(mesh.position, const Vec3(5, 1, 0));
      expect(demands, 0);
    },
  );

  test(
    'play acquires one demand and completion, pause and detach release it',
    () async {
      timeline.play();
      timeline.play();
      expect(demands, 1);
      for (var i = 0; i <= 10; i++) {
        await engine.render(
          elapsed: Duration(milliseconds: i * 100),
          width: 8,
          height: 8,
        );
      }
      expect(timeline.position, end);
      expect(timeline.isPlaying, isFalse);
      expect(demands, 0);
      timeline.play();
      expect(timeline.position, Duration.zero);
      timeline.pause();
      expect(demands, 0);
      timeline.play();
      await engine.dispose();
      expect(demands, 0);
      expect(timeline.isPlaying, isFalse);
      expect(() => timeline.play(), throwsStateError);
    },
  );

  test(
    'loop retains overshoot and resuming does not consume idle time',
    () async {
      timeline.loop = true;
      timeline.seek(const Duration(milliseconds: 950));
      timeline.play();
      await engine.render(elapsed: Duration.zero, width: 8, height: 8);
      await engine.render(
        elapsed: const Duration(milliseconds: 100),
        width: 8,
        height: 8,
      );
      expect(timeline.position, const Duration(milliseconds: 50));
      timeline.pause();
      timeline.play();
      await engine.render(
        elapsed: const Duration(seconds: 10),
        width: 8,
        height: 8,
      );
      expect(timeline.position, const Duration(milliseconds: 50));
    },
  );

  test('removed targets stop playback without applying another pose', () async {
    timeline.play();
    scene.remove(mesh);
    expect(() => timeline.seek(end), throwsStateError);
    expect(mesh.position, Vec3.zero);
    expect(timeline.isPlaying, isFalse);
    expect(demands, 0);
  });

  test('invalid keyframes and singular interpolated scale are rejected', () {
    expect(
      () => TransformTrack(mesh, [
        TransformKeyframe(end),
        TransformKeyframe(Duration.zero),
      ]),
      throwsArgumentError,
    );
    expect(
      () => TransformTrack(mesh, [
        TransformKeyframe(Duration.zero),
        TransformKeyframe(Duration.zero),
      ]),
      throwsArgumentError,
    );
    expect(
      () => TransformTrack(mesh, [
        TransformKeyframe(Duration.zero),
        TransformKeyframe(end, scale: const Vec3(-1, 1, 1)),
      ]),
      throwsArgumentError,
    );
    expect(
      () => TransformKeyframe(end, position: const Vec3(double.nan, 0, 0)),
      throwsArgumentError,
    );
    expect(
      () => SceneTimelinePlugin(duration: Duration.zero, tracks: []),
      throwsArgumentError,
    );
  });

  test('opposite quaternion signs follow the same orientation', () {
    final track = TransformTrack(mesh, [
      TransformKeyframe(Duration.zero),
      TransformKeyframe(end, rotation: const Quat(0, 0, 0, -1)),
    ]);
    track.apply(const Duration(milliseconds: 500));
    expect(mesh.quaternion.rotate(const Vec3(1, 0, 0)), const Vec3(1, 0, 0));
  });

  test('an invalid sampled camera leaves earlier tracks unchanged', () async {
    await engine.dispose();
    timeline = SceneTimelinePlugin(
      duration: end,
      tracks: [
        TransformTrack(mesh, [
          TransformKeyframe(Duration.zero),
          TransformKeyframe(end, position: Vec3.one),
        ]),
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
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => TestRenderer([]),
      plugins: [timeline],
    );
    expect(
      () => timeline.seek(const Duration(milliseconds: 500)),
      throwsArgumentError,
    );
    expect(mesh.position, Vec3.zero);
    expect(camera.position, const Vec3(0, 0, 5));
  });
}
