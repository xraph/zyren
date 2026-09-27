import 'dart:async';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';
import 'package:test/test.dart';
import '../../zyren/test/support/fakes.dart';

class _Input implements ViewportInputSource, KeyboardInputSource {
  // Match the asynchronous Flutter adapter, including listener ordering.
  final pointers = StreamController<ScenePointerEvent>.broadcast();
  final keys = StreamController<SceneKeyEvent>.broadcast();
  int registrations = 0;
  @override
  ViewportMetrics viewport = const ViewportMetrics(800, 600);
  @override
  Stream<ScenePointerEvent> get events => pointers.stream;
  @override
  Stream<SceneKeyEvent> get keyEvents => keys.stream;
  Registration _register() {
    registrations++;
    return Registration(() => registrations--);
  }

  @override
  Registration registerGesture(SceneGesture gesture) => _register();
  @override
  Registration registerKeys(Set<SceneKey> keys) => _register();
}

void main() {
  late Scene scene;
  late Group parent;
  late Mesh mesh;
  late SceneToolsPlugin tools;
  late TransformGizmoPlugin gizmo;
  late OrbitControlsPlugin orbit;
  late SceneEngine engine;
  late Camera camera;
  late _Input input;
  Future<void> flush() => Future<void>.delayed(Duration.zero);
  ViewportPoint project(Vec3 point) {
    final p = camera.projectPoint(point, input.viewport.aspect);
    return ViewportPoint(
      (p.x + 1) * input.viewport.width / 2,
      (1 - p.y) * input.viewport.height / 2,
    );
  }

  Future<void> pointer(
    ScenePointerPhase phase,
    Vec3 world, {
    int id = 1,
    Set<SceneModifier> modifiers = const {},
  }) async {
    input.pointers.add(
      ScenePointerEvent(
        phase: phase,
        point: project(world),
        pointer: id,
        kind: ScenePointerKind.mouse,
        buttons: 1,
        modifiers: modifiers,
      ),
    );
    await flush();
  }

  setUp(() async {
    scene = Scene();
    parent = scene.add(Group());
    mesh = parent.add(
      Mesh(BoxGeometry(width: .4, height: .4, depth: .4), DiffuseMaterial()),
    );
    camera = PerspectiveCamera(position: const Vec3(4, 3, 6));
    tools = SceneToolsPlugin();
    orbit = OrbitControlsPlugin();
    gizmo = TransformGizmoPlugin(
      onDragChanged: (active) => orbit.controls?.enabled = !active,
    );
    input = _Input();
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => TestRenderer([]),
      plugins: [tools, gizmo, orbit],
      input: input,
    );
    tools.select(mesh);
    await flush();
  });
  tearDown(() async {
    await engine.dispose();
    await input.pointers.close();
    await input.keys.close();
  });

  test(
    'native move handles capture the pointer and commit a single undo',
    () async {
      final cameraPosition = camera.position;
      expect(
        gizmo.hitTest(project(const Vec3(1.45, 0, 0)), input.viewport),
        GizmoAxis.x,
      );
      await pointer(ScenePointerPhase.down, const Vec3(1.45, 0, 0));
      expect(gizmo.isDragging, isTrue);
      expect(orbit.controls!.enabled, isFalse);
      await pointer(ScenePointerPhase.move, const Vec3(1.75, 0, 0));
      await pointer(ScenePointerPhase.move, const Vec3(2, 0, 0));
      await pointer(ScenePointerPhase.up, const Vec3(2, 0, 0));
      expect(mesh.position.x, closeTo(.55, 1e-9));
      expect(camera.position, cameraPosition);
      expect(gizmo.isDragging, isFalse);
      expect(orbit.controls!.enabled, isTrue);
      expect(tools.undo(), isTrue);
      expect(mesh.position, Vec3.zero);
      expect(tools.undo(), isFalse);
      await pointer(ScenePointerPhase.down, const Vec3(-2, -2, 0));
      await pointer(ScenePointerPhase.move, const Vec3(-1, -2, 0));
      await pointer(ScenePointerPhase.up, const Vec3(-1, -2, 0));
      expect(camera.position, isNot(cameraPosition));
    },
  );

  test(
    'translation honors rotated local axes and nonuniform parent scale',
    () async {
      parent.scale = const Vec3(2, 3, 1);
      parent.position = const Vec3(-1, -2, 0);
      mesh.quaternion = Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2);
      await flush();
      await pointer(ScenePointerPhase.down, const Vec3(-1, 2.35, 0));
      expect(gizmo.activeAxis, GizmoAxis.x);
      await pointer(ScenePointerPhase.up, const Vec3(-1, 3.25, 0));
      expect(mesh.position.x, closeTo(0, 1e-9));
      expect(mesh.position.y, closeTo(.3, 1e-9));
      expect(mesh.position.z, 0);
    },
  );

  test(
    'shift snaps along one axis without snapping untouched coordinates',
    () async {
      mesh.position = const Vec3(.03, .07, .09);
      await flush();
      await pointer(ScenePointerPhase.down, const Vec3(1.48, .07, .09));
      await pointer(
        ScenePointerPhase.up,
        const Vec3(1.79, .07, .09),
        modifiers: {SceneModifier.shift},
      );
      expect(mesh.position.x, closeTo(.28, 1e-9));
      expect(mesh.position.y, .07);
      expect(mesh.position.z, .09);
    },
  );

  test('rotation rings produce local rotation and snap radians', () async {
    gizmo.mode = GizmoMode.rotate;
    const radius = 1.5 * .85;
    Vec3 point(double angle) =>
        Vec3(radius * math.cos(angle), radius * math.sin(angle), 0);
    await pointer(ScenePointerPhase.down, point(math.pi / 4));
    expect(gizmo.activeAxis, GizmoAxis.z);
    await pointer(
      ScenePointerPhase.move,
      point(math.pi / 4 + .33),
      modifiers: {SceneModifier.shift},
    );
    await pointer(
      ScenePointerPhase.up,
      point(math.pi / 4 + .33),
      modifiers: {SceneModifier.shift},
    );
    final expected = Quat.axisAngle(
      const Vec3(0, 0, 1),
      math.pi / 12,
    ).rotate(const Vec3(1, 0, 0));
    expect(
      mesh.quaternion.rotate(const Vec3(1, 0, 0)).distanceTo(expected),
      lessThan(1e-9),
    );
    tools.undo();
    expect(mesh.quaternion, Quat.identity);
  });

  test('scale handles constrain one component and cannot cross zero', () async {
    gizmo.mode = GizmoMode.scale;
    mesh.scale = const Vec3(-1, 2, 3);
    await pointer(ScenePointerPhase.down, const Vec3(1.5, 0, 0));
    expect(gizmo.activeAxis, GizmoAxis.x);
    await pointer(ScenePointerPhase.move, const Vec3(2.25, 0, 0));
    expect(mesh.scale.x, closeTo(-1.5, 1e-9));
    expect(mesh.scale.y, 2);
    expect(mesh.scale.z, 3);
    await pointer(ScenePointerPhase.up, const Vec3(-2, 0, 0));
    expect(mesh.scale.x, closeTo(-.05, 1e-9));
    tools.undo();
    expect(mesh.scale, const Vec3(-1, 2, 3));
  });

  test('escape and pointer cancellation restore the pose', () async {
    for (final escape in [true, false]) {
      await pointer(ScenePointerPhase.down, const Vec3(1.45, 0, 0));
      await pointer(ScenePointerPhase.move, const Vec3(2, 0, 0));
      if (escape) {
        input.keys.add(SceneKeyEvent(SceneKey.escape, SceneKeyPhase.down));
        await flush();
      } else {
        await pointer(ScenePointerPhase.cancel, const Vec3(2, 0, 0));
      }
      expect(mesh.position, Vec3.zero);
      expect(tools.canUndo, isFalse);
      expect(orbit.controls!.enabled, isTrue);
    }
  });

  test(
    'other pointers cannot finish a drag and external edits cancel safely',
    () async {
      await pointer(ScenePointerPhase.down, const Vec3(1.45, 0, 0));
      await pointer(ScenePointerPhase.up, const Vec3(2, 0, 0), id: 2);
      expect(gizmo.isDragging, isTrue);
      mesh.position = Vec3.one;
      await flush();
      expect(gizmo.isDragging, isFalse);
      expect(mesh.position, Vec3.one);
      expect(tools.canUndo, isFalse);
    },
  );

  test(
    'hidden and clipped handles cannot be picked and tools ignore helpers',
    () async {
      final point = project(const Vec3(1.45, 0, 0));
      expect(tools.pick(point, input.viewport), isNull);
      tools.clearMeasurements();
      expect(tools.pick(point, input.viewport), isNull);
      final blocker = scene.add(
        Mesh(BoxGeometry(width: 3, height: 3, depth: 3), DiffuseMaterial()),
      );
      blocker.position = const Vec3(1.45, 0, 0);
      expect(gizmo.hitTest(point, input.viewport), isNull);
      scene.remove(blocker);
      parent.visible = false;
      expect(gizmo.hitTest(point, input.viewport), isNull);
      parent.visible = true;
      (camera as PerspectiveCamera).far = 1;
      expect(gizmo.hitTest(point, input.viewport), isNull);
    },
  );

  test(
    'mode, camera, selection and viewport changes cancel active previews',
    () async {
      for (final change in [
        () => gizmo.mode = GizmoMode.scale,
        () => camera.position = const Vec3(4, 4, 6),
        () => tools.select(null),
        () => input.viewport = const ViewportMetrics(700, 600),
      ]) {
        gizmo.mode = GizmoMode.translate;
        tools.select(mesh);
        await flush();
        await pointer(ScenePointerPhase.down, const Vec3(1.45, 0, 0));
        expect(gizmo.isDragging, isTrue);
        await pointer(ScenePointerPhase.move, const Vec3(2, 0, 0));
        change();
        await pointer(ScenePointerPhase.move, const Vec3(2, 0, 0));
        expect(gizmo.isDragging, isFalse);
        expect(mesh.position, Vec3.zero);
      }
    },
  );

  test('teardown removes helper geometry and releases input', () async {
    await pointer(ScenePointerPhase.down, const Vec3(1.45, 0, 0));
    await pointer(ScenePointerPhase.move, const Vec3(2, 0, 0));
    await engine.dispose();
    expect(parent.children, [mesh]);
    expect(input.registrations, 0);
    expect(mesh.position, Vec3.zero);
  });

  test(
    'orthographic handles work and an end-on axis does not capture',
    () async {
      camera = OrthographicCamera(
        position: const Vec3(0, 0, 6),
        left: -4,
        right: 4,
        top: 3,
        bottom: -3,
      );
      engine.camera = camera;
      // Z is visible but has no stable screen direction from this camera.
      await pointer(ScenePointerPhase.down, const Vec3(0, 0, 1.45));
      expect(gizmo.isDragging, isFalse);
      await pointer(ScenePointerPhase.up, const Vec3(0, 0, 1.45));
      await pointer(ScenePointerPhase.down, const Vec3(1.45, 0, 0));
      expect(gizmo.activeAxis, GizmoAxis.x);
      await pointer(ScenePointerPhase.up, const Vec3(1.95, 0, 0));
      expect(mesh.position.x, closeTo(.5, 1e-9));
    },
  );

  test('rotation crosses the angle seam without reversing', () async {
    gizmo.mode = GizmoMode.rotate;
    Vec3 point(double angle) =>
        Vec3(1.275 * math.cos(angle), 1.275 * math.sin(angle), 0);
    await pointer(ScenePointerPhase.down, point(3));
    expect(gizmo.activeAxis, GizmoAxis.z);
    await pointer(ScenePointerPhase.move, point(-3));
    await pointer(ScenePointerPhase.up, point(-2.8));
    final expected = Quat.axisAngle(const Vec3(0, 0, 1), 2 * math.pi - 5.8);
    expect(mesh.quaternion.z, closeTo(expected.z, 1e-9));
  });
}
