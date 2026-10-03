import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'router_test.dart' show TestInput;

class FocusInput extends TestInput
    implements KeyboardInputSource, FocusInputSource {
  final keys = StreamController<SceneKeyEvent>.broadcast(sync: true);
  final focusEvents = StreamController<bool>.broadcast(sync: true);
  final interestsKeys = <SceneKey>{};
  @override
  bool hasFocus = true;
  @override
  Stream<bool> get focusChanges => focusEvents.stream;
  @override
  Stream<SceneKeyEvent> get keyEvents => keys.stream;
  @override
  Registration registerKeys(Set<SceneKey> keys) {
    interestsKeys.addAll(keys);
    return Registration(() => interestsKeys.removeAll(keys));
  }
}

void main() {
  test(
    'focus traverses by order, activates and clears on focus loss/removal',
    () async {
      final scene = Scene();
      final a = scene.add(Object3D()), b = scene.add(Object3D());
      final focus = SceneObjectFocus(scene);
      var activations = 0;
      final first = focus.register(
        a,
        label: 'A',
        order: 2,
        onActivate: () => activations++,
      );
      final second = focus.register(b, label: 'B', order: 1);
      final input = FocusInput();
      final connection = focus.connect(input);
      input.keys.add(SceneKeyEvent(SceneKey.tab, SceneKeyPhase.down));
      expect(focus.focusedObject, b);
      input.keys.add(SceneKeyEvent(SceneKey.tab, SceneKeyPhase.down));
      input.keys.add(SceneKeyEvent(SceneKey.enter, SceneKeyPhase.down));
      expect(focus.focusedObject, a);
      expect(activations, 1);
      input.keys.add(
        SceneKeyEvent(
          SceneKey.tab,
          SceneKeyPhase.down,
          modifiers: {SceneModifier.shift},
        ),
      );
      expect(focus.focusedObject, b);
      input.keys.add(SceneKeyEvent(SceneKey.escape, SceneKeyPhase.down));
      expect(focus.focusedObject, isNull);
      focus.request(a);
      input.focusEvents.add(false);
      expect(focus.focusedObject, isNull);
      focus.request(a);
      a.visible = false;
      await Future<void>.delayed(Duration.zero);
      expect(focus.focusedObject, isNull);
      expect(focus.activate(a), isFalse);
      a.visible = true;
      focus.request(a);
      scene.remove(a);
      await Future<void>.delayed(Duration.zero);
      expect(focus.focusedObject, isNull);
      expect(focus.targets.map((t) => t.object), [b]);
      first.dispose();
      second.dispose();
      expect(input.interestsKeys, isEmpty);
      connection.dispose();
      focus.dispose();
      await input.keys.close();
      await input.focusEvents.close();
      await input.controller.close();
    },
  );
  test(
    'anchors follow transforms, resize, camera replacement and clipping',
    () {
      final scene = Scene();
      final parent = scene.add(Object3D())..position = const Vec3(1, 0, 0);
      final child = parent.add(Object3D());
      Camera camera = OrthographicCamera(verticalSize: 4);
      var viewport = const ViewportMetrics(200, 200, devicePixelRatio: 3);
      final projector = SceneAnchorProjector(
        scene: scene,
        camera: () => camera,
        viewport: () => viewport,
      );
      final anchor = SceneAnchor(child);
      expect(projector.project(anchor).point!.x, closeTo(150, 1e-6));
      viewport = const ViewportMetrics(400, 200);
      expect(projector.project(anchor).point!.x, closeTo(250, 1e-6));
      parent.position = const Vec3(0, 0, 6);
      expect(
        projector.project(anchor).visibility,
        AnchorVisibility.outsideViewport,
      );
      parent.position = Vec3.zero;
      camera = PerspectiveCamera(position: const Vec3(2, 0, 5));
      expect(projector.project(anchor).point!.x, closeTo(200, 1e-6));
      scene.clippingPlanes = [
        ClippingPlane(normal: const Vec3(1, 0, 0), offset: 1),
      ];
      expect(
        projector.project(anchor).visibility,
        AnchorVisibility.outsideViewport,
      );
      scene.clippingPlanes = [];
      parent.visible = false;
      expect(projector.project(anchor).visibility, AnchorVisibility.hidden);
      parent.visible = true;
      scene.remove(parent);
      expect(projector.project(anchor).visibility, AnchorVisibility.detached);
      projector.dispose();
      expect(() => projector.project(anchor), throwsStateError);
    },
  );
  test('optional triangle occlusion hides anchors behind another object', () {
    final scene = Scene();
    final label = scene.add(Object3D());
    final blocker = scene.add(Mesh(BoxGeometry(), UnlitMaterial()))
      ..position = const Vec3(0, 0, 2);
    final projector = SceneAnchorProjector(
      scene: scene,
      camera: () => PerspectiveCamera(),
      viewport: () => const ViewportMetrics(100, 100),
    );
    expect(projector.project(SceneAnchor(label)).visible, isTrue);
    expect(
      projector.project(SceneAnchor(label, testOcclusion: true)).visibility,
      AnchorVisibility.occluded,
    );
    blocker.visible = false;
    expect(
      projector.project(SceneAnchor(label, testOcclusion: true)).visible,
      isTrue,
    );
    projector.dispose();
  });
}
