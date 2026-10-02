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
}
