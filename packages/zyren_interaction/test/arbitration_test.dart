import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import '../../zyren/test/support/fakes.dart';
import 'router_test.dart' show TestInput;

void main() {
  for (final cameraFirst in [true, false]) {
    test(
      'object ownership precedes camera, cameraFirst=$cameraFirst',
      () async {
        final input = TestInput();
        final scene = Scene()..add(Mesh(BoxGeometry(), UnlitMaterial()));
        final camera = PerspectiveCamera();
        final orbit = OrbitControlsPlugin();
        final router = SceneInteractionRouter(
          scene: scene,
          camera: () => camera,
          viewport: () => input.viewport,
        );
        final phases = <ObjectPointerPhase>[];
        router.register(scene.children.single, (e) {
          phases.add(e.phase);
          if (e.phase == ObjectPointerPhase.down) e.capturePointer();
        });
        final objectPlugin = SceneInteractionPlugin(router);
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          rendererFactory: () async => TestRenderer([]),
          input: input,
          plugins: cameraFirst ? [orbit, objectPlugin] : [objectPlugin, orbit],
        );
        final before = camera.position;
        void event(
          ScenePointerPhase phase,
          double x, {
          int id = 1,
          ScenePointerKind kind = ScenePointerKind.mouse,
        }) => input.controller.add(
          ScenePointerEvent(
            point: ViewportPoint(x, 100),
            phase: phase,
            pointer: id,
            buttons: 1,
            kind: kind,
          ),
        );
        event(ScenePointerPhase.down, 100);
        event(ScenePointerPhase.move, 150);
        await Future<void>.delayed(Duration.zero);
        orbit.controls!.update();
        expect(camera.position, before);
        expect(router.capturedObject(1), isNotNull);
        event(ScenePointerPhase.up, 150);
        event(ScenePointerPhase.down, 10);
        event(ScenePointerPhase.move, 30);
        await Future<void>.delayed(Duration.zero);
        orbit.controls!.update();
        expect(camera.position, isNot(before));
        event(ScenePointerPhase.cancel, 30);
        camera.position = before;
        camera.target = Vec3.zero;
        orbit.controls!.update();
        event(ScenePointerPhase.down, 100, kind: ScenePointerKind.touch);
        event(ScenePointerPhase.down, 140, id: 2, kind: ScenePointerKind.touch);
        await Future<void>.delayed(Duration.zero);
        expect(phases, contains(ObjectPointerPhase.cancel));
        expect(router.capturedObjects, isEmpty);
        expect(InputRouter.forSource(input).owners.values.toSet(), {orbit.id});
        event(ScenePointerPhase.move, 170, id: 2, kind: ScenePointerKind.touch);
        await Future<void>.delayed(Duration.zero);
        orbit.controls!.update();
        expect(camera.position, isNot(before));
        await engine.dispose();
        expect(InputRouter.forSource(input).owners, isEmpty);
        router.dispose();
        await input.controller.close();
      },
    );
  }
  test(
    'tools outrank objects; blocking cancels once and ignores orphan moves',
    () async {
      final input = TestInput();
      final arbiter = InputRouter.forSource(input);
      final events = <String>[];
      final object = arbiter.register(
        id: 'object',
        priority: InputPriority.objects,
        claims: (_) => true,
        onEvent: (e) => events.add('object:${e.phase.name}'),
      );
      final tool = arbiter.register(
        id: 'tool',
        priority: InputPriority.tools,
        claims: (_) => true,
        onEvent: (e) => events.add('tool:${e.phase.name}'),
      );
      void emit(ScenePointerPhase phase) => input.controller.add(
        ScenePointerEvent(point: const ViewportPoint(1, 1), phase: phase),
      );
      emit(ScenePointerPhase.down);
      await Future<void>.delayed(Duration.zero);
      final block = arbiter.block();
      emit(ScenePointerPhase.move);
      await Future<void>.delayed(Duration.zero);
      block.dispose();
      emit(ScenePointerPhase.move);
      emit(ScenePointerPhase.up);
      await Future<void>.delayed(Duration.zero);
      expect(events, ['tool:down', 'tool:cancel']);
      tool.dispose();
      object.dispose();
      expect(input.controller.hasListener, isFalse);
      await input.controller.close();
    },
  );
}
