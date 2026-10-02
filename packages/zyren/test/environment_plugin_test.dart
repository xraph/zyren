import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'support/fakes.dart';

class _Input implements ViewportInputSource {
  final pointers = StreamController<ScenePointerEvent>.broadcast(sync: true);
  final interests = <SceneGesture>{};
  @override
  Stream<ScenePointerEvent> get events => pointers.stream;
  @override
  ViewportMetrics viewport = const ViewportMetrics(800, 600);
  @override
  Registration registerGesture(SceneGesture gesture) {
    interests.add(gesture);
    return Registration(() => interests.remove(gesture));
  }

  void event(ScenePointerPhase phase, double x, [int buttons = 1]) =>
      pointers.add(
        ScenePointerEvent(
          point: ViewportPoint(x, 300),
          phase: phase,
          buttons: buttons,
          kind: ScenePointerKind.mouse,
        ),
      );
}

void main() {
  test(
    'surface plugin settles, rebinds camera, resizes and releases input',
    () async {
      final input = _Input(),
          plugin = EnvironmentControlsPlugin(
            configure: (controls) => controls.enableDamping = true,
          );
      var requests = 0;
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(position: const Vec3(40, 60, 100)),
        rendererFactory: () async => TestRenderer([]),
        plugins: [plugin],
        input: input,
        onInvalidate: () => requests++,
      );
      expect(input.interests, {SceneGesture.pointerDrag, SceneGesture.scroll});
      var frame = 0;
      Future<void> render() async {
        await engine.render(
          elapsed: Duration(milliseconds: frame++ * 17),
          width: 8,
          height: 6,
        );
      }

      await render();
      final before = engine.camera.position;
      input.event(ScenePointerPhase.down, 300);
      input.event(ScenePointerPhase.move, 360);
      await render();
      expect(engine.camera.position, isNot(before));
      input.event(ScenePointerPhase.up, 360);
      while (plugin.controls!.needsUpdate && frame < 800) {
        await render();
      }
      expect(frame, lessThan(800));
      final count = requests;
      await render();
      expect(requests, count);
      final previous = plugin.controls!;
      engine.camera = OrthographicCamera(position: const Vec3(40, 60, 100));
      input.viewport = const ViewportMetrics(390, 700);
      await render();
      expect(plugin.controls!.camera, same(engine.camera));
      expect(plugin.controls!.viewport.width, 390);
      expect(() => previous.update(.1), throwsStateError);
      input.event(ScenePointerPhase.down, 150);
      input.event(ScenePointerPhase.move, 190);
      input.event(ScenePointerPhase.cancel, 190);
      expect(plugin.controls!.state, EnvironmentState.none);
      expect(plugin.controls!.needsUpdate, isFalse);
      await engine.dispose();
      expect(input.interests, isEmpty);
      expect(input.pointers.hasListener, isFalse);
      expect(plugin.controls, isNull);
      await input.pointers.close();
    },
  );
}
