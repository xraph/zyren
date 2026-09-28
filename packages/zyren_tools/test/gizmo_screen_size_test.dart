import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_tools/zyren_tools.dart';
import 'package:test/test.dart';
import '../../zyren/test/support/fakes.dart';

class _Input implements ViewportInputSource {
  @override
  ViewportMetrics viewport = const ViewportMetrics(800, 600);
  @override
  Stream<ScenePointerEvent> get events => const Stream.empty();
  @override
  Registration registerGesture(SceneGesture gesture) => Registration(() {});
}

Mat4 world(Object3D object) => object.parent == null
    ? object.localMatrix
    : world(object.parent!) * object.localMatrix;

Vec3 point(Mat4 m, Vec3 p) => Vec3(
  m.storage[0] * p.x + m.storage[4] * p.y + m.storage[8] * p.z + m.storage[12],
  m.storage[1] * p.x + m.storage[5] * p.y + m.storage[9] * p.z + m.storage[13],
  m.storage[2] * p.x + m.storage[6] * p.y + m.storage[10] * p.z + m.storage[14],
);

Iterable<Object3D> descendants(Object3D object) sync* {
  for (final child in object.children) {
    yield child;
    yield* descendants(child);
  }
}

void main() {
  late Scene scene;
  late Group parent;
  late Mesh mesh;
  late SceneToolsPlugin tools;
  late TransformGizmoPlugin gizmo;
  late SceneEngine engine;
  late Camera camera;
  late _Input input;

  ViewportPoint project(Vec3 p) {
    final ndc = camera.projectPoint(p, input.viewport.aspect);
    return ViewportPoint(
      (ndc.x + 1) * input.viewport.width / 2,
      (1 - ndc.y) * input.viewport.height / 2,
    );
  }

  Object3D named(String name) =>
      descendants(scene).firstWhere((o) => o.name == name);
  double radius() => gizmo.size * named('Handle visuals').scale.x;
  double projectedXTip() {
    final arrow = descendants(scene).lastWhere((o) => o.name == 'translate x');
    final origin = project(point(world(mesh), Vec3.zero));
    final tip = project(point(world(arrow), Vec3(gizmo.size * 1.12, 0, 0)));
    return math.sqrt(
      math.pow(tip.x - origin.x, 2) + math.pow(tip.y - origin.y, 2),
    );
  }

  Future<void> render({int pixels = 32}) async {
    await engine.render(elapsed: Duration.zero, width: pixels, height: pixels);
  }

  void pointer(ScenePointerPhase phase, Vec3 position) => gizmo.handlePointer(
    ScenePointerEvent(
      phase: phase,
      point: project(position),
      pointer: 1,
      buttons: 1,
    ),
    input.viewport,
  );

  setUp(() async {
    scene = Scene();
    parent = scene.add(Group());
    mesh = parent.add(
      Mesh(BoxGeometry(width: .4, height: .4, depth: .4), DiffuseMaterial()),
    );
    camera = PerspectiveCamera(position: const Vec3(0, 0, 10));
    tools = SceneToolsPlugin();
    gizmo = TransformGizmoPlugin(screenSize: 96);
    input = _Input();
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => TestRenderer([]),
      plugins: [tools, gizmo],
      input: input,
    );
    tools.select(mesh);
    await render();
  });
  tearDown(() => engine.dispose());

  test('screen size rejects zero, negative and nonfinite radii', () {
    for (final value in [0.0, -1.0, double.nan, double.infinity]) {
      expect(
        () => TransformGizmoPlugin(screenSize: value),
        throwsArgumentError,
      );
    }
  });

  test(
    'perspective size tracks distance, field of view, zoom and pivot depth',
    () async {
      final perspective = camera as PerspectiveCamera;
      for (final distance in [5.0, 10.0, 40.0]) {
        camera.position = Vec3(0, 0, distance);
        for (final zoom in [1.0, 2.0]) {
          perspective.zoom = zoom;
          perspective.fieldOfView = .9;
          mesh.position = const Vec3(.4, -.2, -1);
          await render();
          expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
        }
      }
      perspective.fieldOfView = .5;
      await render();
      expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
    },
  );

  test(
    'logical viewport resize changes size but density and render resolution do not',
    () async {
      final before = radius();
      input.viewport = const ViewportMetrics(800, 600, devicePixelRatio: 3);
      await render(pixels: 64);
      expect(radius(), closeTo(before, 1e-10));
      for (final viewport in [
        const ViewportMetrics(600, 400),
        const ViewportMetrics(1200, 900),
      ]) {
        input.viewport = viewport;
        await render();
        expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
      }
    },
  );

  test(
    'small viewports cap the radius at a third of the shorter edge',
    () async {
      for (final viewport in [
        const ViewportMetrics(240, 180),
        const ViewportMetrics(180, 240),
      ]) {
        input.viewport = viewport;
        await render();
        expect(projectedXTip(), closeTo(60 * 1.12, 1e-8));
      }
    },
  );

  test('orthographic size follows zoom and bounds but not distance', () async {
    final ortho = OrthographicCamera(
      position: const Vec3(0, 0, 10),
      left: -3,
      right: 5,
      bottom: -2,
      top: 4,
    );
    camera = ortho;
    engine.camera = ortho;
    for (final zoom in [.5, 2.0]) {
      ortho.zoom = zoom;
      await render();
      expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
      final before = radius();
      ortho.position = const Vec3(0, 0, 20);
      await render();
      expect(radius(), closeTo(before, 1e-10));
    }
    ortho.setFrustum(left: -6, right: 10, bottom: -4, top: 8);
    await render();
    expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
  });

  test(
    'parent scale is normalized and selected scale cannot enlarge handles',
    () async {
      for (final scale in [const Vec3(3, 3, 3), const Vec3(-4, 2, 1)]) {
        parent.scale = scale;
        mesh.scale = const Vec3(.1, 3, 2);
        await render();
        expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
      }
      final outer = scene.add(Group()..scale = const Vec3(2, 3, 1));
      outer.add(parent);
      parent.quaternion = Quat.axisAngle(const Vec3(0, 0, 1), .4);
      gizmo.space = GizmoSpace.world;
      await render();
      expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
    },
  );

  test(
    'screen scaling preserves translation units and two-coordinate snapping',
    () async {
      gizmo.space = GizmoSpace.world;
      for (final distance in [10.0, 30.0]) {
        camera.position = Vec3(0, 0, distance);
        parent.scale = const Vec3(2, 3, 1);
        await render();
        final start = Vec3(radius() * .65, radius() * .65, 0);
        expect(
          gizmo.hitTestHandle(project(start), input.viewport),
          GizmoPlane.xy,
        );
        gizmo.snapEnabled = true;
        pointer(ScenePointerPhase.down, start);
        pointer(ScenePointerPhase.up, start + const Vec3(.31, .56, 0));
        expect(
          mesh.position.distanceTo(const Vec3(.125, 1 / 6, 0)),
          lessThan(1e-8),
        );
        expect(tools.undo(), isTrue);
        expect(mesh.position, Vec3.zero);
        expect(tools.redo(), isTrue);
        expect(tools.undo(), isTrue);
      }
    },
  );

  test(
    'scale sensitivity uses the displayed radius and rotation stays angular',
    () async {
      for (final distance in [10.0, 30.0]) {
        camera.position = Vec3(0, 0, distance);
        gizmo.mode = GizmoMode.scale;
        await render();
        final r = radius();
        pointer(ScenePointerPhase.down, Vec3(r, 0, 0));
        expect(gizmo.activeAxis, GizmoAxis.x);
        pointer(ScenePointerPhase.up, Vec3(r * 1.5, 0, 0));
        expect(mesh.scale.x, closeTo(1.5, 1e-8));
        expect(mesh.scale.y, 1);
        expect(tools.undo(), isTrue);
        gizmo.mode = GizmoMode.rotate;
        Vec3 ring(double a) =>
            Vec3(r * .85 * math.cos(a), r * .85 * math.sin(a), 0);
        pointer(ScenePointerPhase.down, ring(.7));
        expect(gizmo.activeAxis, GizmoAxis.z);
        pointer(ScenePointerPhase.up, ring(1));
        expect(mesh.quaternion.z, closeTo(math.sin(.15), 1e-8));
        expect(tools.undo(), isTrue);
      }
    },
  );

  test('local movement keeps parent units under nonuniform scale', () async {
    parent.scale = const Vec3(3, 2, 1);
    mesh.quaternion = Quat.axisAngle(const Vec3(0, 0, 1), math.pi / 2);
    await render();
    final start = Vec3(0, radius() * 2, 0);
    pointer(ScenePointerPhase.down, start);
    expect(gizmo.activeAxis, GizmoAxis.x);
    gizmo.snapEnabled = true;
    pointer(ScenePointerPhase.up, start + const Vec3(0, .62, 0));
    expect(mesh.position.distanceTo(const Vec3(0, .25, 0)), lessThan(1e-8));
    expect(tools.undo(), isTrue);
  });

  test(
    'screen-sized handles keep occlusion and do not redraw an unchanged scene',
    () async {
      final start = Vec3(radius(), 0, 0);
      expect(gizmo.hitTest(project(start), input.viewport), GizmoAxis.x);
      scene.add(
        Mesh(BoxGeometry(), DiffuseMaterial())
          ..position = start + const Vec3(0, 0, 1),
      );
      expect(gizmo.hitTest(project(start), input.viewport), isNull);
      await render();
      final revision = scene.revision;
      await render();
      await render();
      expect(scene.revision, revision);
    },
  );

  test('depth movement freezes visual size until release', () async {
    camera.position = const Vec3(4, 3, 10);
    await render();
    final r = radius();
    final start = Vec3(0, 0, r);
    pointer(ScenePointerPhase.down, start);
    expect(gizmo.activeAxis, GizmoAxis.z);
    pointer(ScenePointerPhase.move, start + const Vec3(0, 0, 1));
    await render();
    expect(radius(), closeTo(r, 1e-10));
    pointer(ScenePointerPhase.up, start + const Vec3(0, 0, 1));
    expect(mesh.position.z, closeTo(1, 1e-8));
    expect(radius(), lessThan(r));
    expect(tools.undo(), isTrue);
  });

  test(
    'resize before rendering cancels an owned preview without another pointer event',
    () async {
      final start = Vec3(radius(), 0, 0);
      pointer(ScenePointerPhase.down, start);
      pointer(ScenePointerPhase.move, start + const Vec3(.5, 0, 0));
      expect(mesh.position.x, closeTo(.5, 1e-8));
      input.viewport = const ViewportMetrics(600, 400);
      await render();
      expect(gizmo.isDragging, isFalse);
      expect(mesh.position, Vec3.zero);
      expect(tools.canUndo, isFalse);
      expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
    },
  );

  test(
    'invalid viewports and pivots outside the depth range hide handles',
    () async {
      for (final z in [10.0, 11.0, 9.95, -2000.0]) {
        mesh.position = Vec3(0, 0, z);
        await render();
        expect(named('Transform gizmo').visible, isFalse);
      }
      mesh.position = Vec3.zero;
      for (final v in [
        const ViewportMetrics(0, 0),
        const ViewportMetrics(double.nan, 600),
      ]) {
        input.viewport = v;
        await render();
        expect(named('Transform gizmo').visible, isFalse);
      }
      input.viewport = const ViewportMetrics(800, 600);
      await render();
      expect(named('Transform gizmo').visible, isTrue);
    },
  );

  test('hosts without viewport input supply logical size explicitly', () async {
    await engine.dispose();
    tools = SceneToolsPlugin();
    gizmo = TransformGizmoPlugin(screenSize: 96);
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => TestRenderer([]),
      plugins: [tools, gizmo],
    );
    tools.select(mesh);
    await render();
    // A hidden root may stay detached until the host supplies dimensions.
    expect(
      descendants(scene).where((o) => gizmo.owns(o) && o.visible && o is Mesh),
      isEmpty,
    );
    gizmo.updateViewport(input.viewport);
    await render(pixels: 64);
    expect(projectedXTip(), closeTo(96 * 1.12, 1e-8));
  });
}
