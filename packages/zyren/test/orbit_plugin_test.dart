import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

class _Input implements ViewportInputSource, KeyboardInputSource {
  final pointers = StreamController<ScenePointerEvent>.broadcast(sync: true);
  final keys = StreamController<SceneKeyEvent>.broadcast(sync: true);
  final interests = <SceneGesture>{};
  int keyOwners = 0;
  @override
  Stream<ScenePointerEvent> get events => pointers.stream;
  @override
  Stream<SceneKeyEvent> get keyEvents => keys.stream;
  @override
  ViewportMetrics viewport = const ViewportMetrics(800, 600);
  @override
  Registration registerGesture(SceneGesture gesture) {
    interests.add(gesture);
    return Registration(() => interests.remove(gesture));
  }

  @override
  Registration registerKeys(Set<SceneKey> keys) {
    keyOwners++;
    return Registration(() => keyOwners--);
  }
}

void main() {
  test(
    'r184 plugin auto-rotation follows frame time at 30, 60 and 120 Hz',
    () async {
      final results = <Vec3>[];
      for (final rate in [30, 60, 120]) {
        final plugin = OrbitControlsPlugin(
          behavior: OrbitBehavior.three184,
          configure: (controls) => controls.autoRotate = true,
        );
        final engine = await SceneEngine.create(
          scene: Scene(),
          camera: PerspectiveCamera(position: const Vec3(4, 6, 10)),
          rendererFactory: () async => TestRenderer([]),
          plugins: [plugin],
        );
        final initialAngle = plugin.controls!.azimuthalAngle;
        for (var frame = 0; frame <= rate; frame++) {
          await engine.render(
            elapsed: Duration(microseconds: (frame * 1000000 / rate).round()),
            width: 8,
            height: 6,
          );
        }
        expect(
          plugin.controls!.azimuthalAngle - initialAngle,
          closeTo(-.20943951023931953, 1e-12),
        );
        results.add(engine.camera.position);
        await engine.dispose();
      }
      for (final result in results.skip(1)) {
        expect(result.distanceTo(results.first), lessThan(1e-10));
      }
    },
  );

  test('r184 target limits and invalid time are explicit', () {
    final controls = OrbitControls(
      PerspectiveCamera(),
      behavior: OrbitBehavior.three184,
    );
    controls.cursor = const Vec3(2, 0, 0);
    controls.minTargetRadius = 1;
    controls.maxTargetRadius = 1.5;
    expect(controls.needsUpdate, isTrue);
    controls.update(0);
    expect(controls.target.distanceTo(controls.cursor), closeTo(1.5, 1e-12));
    expect(() => controls.update(-1), throwsArgumentError);
    expect(() => controls.update(double.nan), throwsArgumentError);
    controls.maxTargetRadius = .5;
    expect(() => controls.update(), throwsArgumentError);
    controls.dispose();
  });

  test(
    'plugin settles damping, replaces camera and releases input on disposal',
    () async {
      final input = _Input();
      final plugin = OrbitControlsPlugin(
        keyboard: true,
        configure: (controls) {
          controls.enableDamping = true;
        },
      );
      var requests = 0;
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(position: const Vec3(4, 6, 10)),
        rendererFactory: () async => TestRenderer([]),
        plugins: [plugin],
        input: input,
        onInvalidate: () => requests++,
      );
      expect(input.interests, {SceneGesture.pointerDrag, SceneGesture.scroll});
      expect(input.keyOwners, 1);
      void event(ScenePointerPhase phase, double x) => input.pointers.add(
        ScenePointerEvent(
          point: ViewportPoint(x, 200),
          phase: phase,
          buttons: 1,
          kind: ScenePointerKind.mouse,
        ),
      );
      final before = engine.camera.position;
      event(ScenePointerPhase.down, 200);
      event(ScenePointerPhase.move, 250);
      event(ScenePointerPhase.up, 250);
      expect(engine.camera.position, isNot(before));
      expect(plugin.controls!.needsUpdate, isTrue);
      var frame = 0;
      while (plugin.controls!.needsUpdate && frame < 800) {
        await engine.render(
          elapsed: Duration(milliseconds: ++frame * 17),
          width: 8,
          height: 6,
        );
      }
      expect(plugin.controls!.needsUpdate, isFalse);
      expect(frame, lessThan(800));
      final settled = engine.camera.position, count = requests;
      await engine.render(
        elapsed: Duration(milliseconds: ++frame * 17),
        width: 8,
        height: 6,
      );
      expect(engine.camera.position, settled);
      expect(requests, count);
      final previousDistance = plugin.controls!.distance;
      plugin.controls!.minDistance = previousDistance + 5;
      await engine.render(
        elapsed: Duration(milliseconds: ++frame * 17),
        width: 8,
        height: 6,
      );
      expect(plugin.controls!.distance, closeTo(previousDistance + 5, 1e-9));
      event(ScenePointerPhase.down, 200);
      event(ScenePointerPhase.move, 250);
      event(ScenePointerPhase.up, 250);
      plugin.controls!.enableDamping = false;
      await engine.render(
        elapsed: Duration(milliseconds: ++frame * 17),
        width: 8,
        height: 6,
      );
      expect(plugin.controls!.needsUpdate, isFalse);
      final old = plugin.controls!;
      engine.camera = OrthographicCamera(position: const Vec3(5, 5, 5));
      await engine.render(
        elapsed: Duration(milliseconds: ++frame * 17),
        width: 8,
        height: 6,
      );
      expect(plugin.controls!.camera, same(engine.camera));
      expect(plugin.controls!.enableDamping, isTrue);
      expect(input.keyOwners, 1);
      expect(() => old.update(), throwsStateError);
      final current = plugin.controls!;
      await engine.dispose();
      expect(input.interests, isEmpty);
      expect(input.keyOwners, 0);
      expect(plugin.controls, isNull);
      expect(() => current.update(), throwsStateError);
      event(ScenePointerPhase.move, 100);
      await input.pointers.close();
      await input.keys.close();
    },
  );

  test(
    'disabled input, zero damping, invalid edits and disposal are explicit',
    () {
      final camera = PerspectiveCamera();
      final controls = OrbitControls(camera)
        ..enableDamping = true
        ..dampingFactor = 0;
      final before = camera.position;
      controls.handlePointer(
        ScenePointerEvent(
          point: const ViewportPoint(.3, .2),
          phase: ScenePointerPhase.down,
          buttons: 1,
        ),
      );
      controls.handlePointer(
        ScenePointerEvent(
          point: const ViewportPoint(.4, .3),
          phase: ScenePointerPhase.move,
          buttons: 1,
        ),
      );
      expect(camera.position.distanceTo(before), lessThan(1e-12));
      expect(controls.needsUpdate, isFalse);
      controls.enabled = false;
      controls.handlePointer(
        ScenePointerEvent(
          point: const ViewportPoint(.4, .3),
          phase: ScenePointerPhase.cancel,
        ),
      );
      expect(controls.isInteracting, isFalse);
      expect(() => controls.setScale(0), throwsArgumentError);
      controls.minDistance = 10;
      controls.maxDistance = 2;
      expect(() => controls.update(), throwsArgumentError);
      controls.dispose();
      controls.dispose();
      expect(() => controls.autoRotate = true, throwsStateError);
    },
  );
}
