import 'dart:math' as math;
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';
import 'orbit_controls_test.dart' show Harness, OrbitInput;

Future<SceneEngine> engine(ScenePlugin control) => SceneEngine.create(
  scene: Scene(),
  camera: PerspectiveCamera(),
  plugins: [control],
  rendererFactory: () async => TestRenderer([]),
);
Future<void> tick(SceneEngine engine, int micros) async => engine.render(
  elapsed: Duration.zero,
  time: FrameTime(
    elapsed: Duration.zero,
    delta: Duration(microseconds: micros),
  ),
  width: 8,
  height: 8,
);
void closeVector(Vec3 actual, Vec3 expected, [double tolerance = 1e-7]) =>
    expect(actual.distanceTo(expected), lessThan(tolerance));
void main() {
  test(
    'trackball crosses poles and rolls without losing its target or radius',
    () async {
      final control = TrackballControls(damping: Duration.zero);
      final view = await engine(control);
      try {
        control.rotateBy(polar: math.pi);
        closeVector(view.camera.position, const Vec3(0, 0, -5));
        closeVector(view.camera.up, const Vec3(0, -1, 0));
        control.rotateBy(roll: math.pi / 2);
        expect(view.camera.up.x.abs(), closeTo(1, 1e-7));
        closeVector(view.camera.target, Vec3.zero);
        control.reset();
        closeVector(view.camera.position, const Vec3(0, 0, 5));
        closeVector(view.camera.up, const Vec3(0, 1, 0));
        control.rotateTrackball(const Vec2(-.5, 0), const Vec2(.5, 0));
        expect(view.camera.position.x.abs(), greaterThan(1));
        expect(view.camera.position.length, closeTo(5, 1e-7));
      } finally {
        await view.dispose();
      }
    },
  );
  test(
    'trackball damping, gestures and cancellation release view state',
    () async {
      final first = Harness(TrackballControls()),
          second = Harness(TrackballControls());
      await first.start();
      await second.start();
      try {
        first.input.send(ScenePointerPhase.scaleStart);
        first.input.send(ScenePointerPhase.scaleUpdate, x: 30);
        first.input.send(ScenePointerPhase.scaleEnd);
        await first.tick(0);
        await first.tick(40);
        expect(first.engine.camera.position.x.abs(), greaterThan(.01));
        closeVector(second.engine.camera.position, const Vec3(0, 0, 5));
        for (var i = 0; i < 150; i++) {
          await first.tick(16);
        }
        expect(first.demands, 0);
        (first.controls as TrackballControls).rotateBy(roll: 1);
        expect(first.demands, 1);
        first.input.send(ScenePointerPhase.cancel);
        expect(first.demands, 0);
      } finally {
        await first.close();
        await second.close();
      }
    },
  );
  test(
    'fly pointer input uses logical viewport and handles cancellation',
    () async {
      final input = OrbitInput(), control = FlyControls();
      final view = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        plugins: [control],
        input: input,
        rendererFactory: () async => TestRenderer([]),
      );
      try {
        input.send(ScenePointerPhase.scaleStart);
        input.send(ScenePointerPhase.scaleUpdate, x: 20);
        expect(view.camera.target.x.abs(), greaterThan(.1));
        control.setMovement(forward: 1);
        input.send(ScenePointerPhase.cancel);
        expect(control.isMoving, isFalse);
        control.enabled = false;
        expect(input.interests.values.every((n) => n == 0), isTrue);
      } finally {
        await view.dispose();
        await input.bus.close();
      }
    },
  );
  test(
    'fly integrates local movement and rotation independently of frame rate',
    () async {
      Future<(Vec3, Vec3, Vec3)> run(int steps) async {
        final control = FlyControls(movementSpeed: 2, rotationSpeed: 1);
        final view = await engine(control);
        try {
          control.setMovement(forward: 1);
          control.setRotation(yaw: 1);
          await tick(view, 0);
          for (var i = 0; i < steps; i++) {
            await tick(view, 1000000 ~/ steps);
          }
          return (view.camera.position, view.camera.target, view.camera.up);
        } finally {
          await view.dispose();
        }
      }

      final a = await run(20), b = await run(100);
      closeVector(a.$1, b.$1);
      closeVector(a.$2, b.$2);
      closeVector(a.$3, b.$3);
      expect(a.$1.distanceTo(const Vec3(0, 0, 5)), greaterThan(1));
    },
  );
  test(
    'fly stop, disable, reset and detach release continuous demand',
    () async {
      var demands = 0;
      final control = FlyControls();
      final view = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        plugins: [control],
        rendererFactory: () async => TestRenderer([]),
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      try {
        control.setMovement(forward: 1);
        expect(demands, 1);
        control.setRotation(roll: .5);
        expect(demands, 1);
        control.enabled = false;
        expect(demands, 0);
        control.enabled = true;
        control.moveBy(const Vec3(1, 2, 3));
        control.reset();
        closeVector(view.camera.position, const Vec3(0, 0, 5));
        expect(() => control.setMovement(forward: 2), throwsArgumentError);
        control.setMovement(right: 1);
        expect(demands, 1);
      } finally {
        await view.dispose();
      }
      expect(demands, 0);
      expect(() => control.moveBy(Vec3.one), throwsStateError);
    },
  );
}
