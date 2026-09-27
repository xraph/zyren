import 'dart:async';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_tools/gpu3d_tools.dart';
import 'package:test/test.dart';
import '../../gpu3d/test/support/fakes.dart';

class Input implements ViewportInputSource {
  final eventsController = StreamController<ScenePointerEvent>.broadcast(
    sync: true,
  );
  int registrations = 0;
  @override
  final viewport = const ViewportMetrics(200, 200);
  @override
  Stream<ScenePointerEvent> get events => eventsController.stream;
  @override
  Registration registerGesture(SceneGesture gesture) {
    registrations++;
    return Registration(() => registrations--);
  }
}

void main() {
  late Scene scene;
  late Mesh mesh;
  late SceneToolsPlugin tools;
  late SceneEngine engine;
  late Input input;
  setUp(() async {
    scene = Scene();
    mesh = scene.add(Mesh(BoxGeometry(), DiffuseMaterial(), name: 'Valve'));
    tools = SceneToolsPlugin(historyLimit: 2);
    input = Input();
    engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: [tools],
      input: input,
    );
  });
  tearDown(() async {
    await engine.dispose();
    await input.eventsController.close();
  });

  test(
    'tap selection restores its material and releases input on detach',
    () async {
      final original = mesh.material;
      input.eventsController.add(
        ScenePointerEvent(
          point: const ViewportPoint(100, 100),
          phase: ScenePointerPhase.tap,
        ),
      );
      expect(tools.selected, same(mesh));
      expect(mesh.material.color, tools.highlightColor);
      tools.select(null);
      expect(mesh.material, same(original));
      tools.select(mesh);
      final replacement = UnlitMaterial(color: const Color3(1, 0, 0));
      mesh.material = replacement;
      await engine.dispose();
      expect(mesh.material, same(replacement));
      expect(input.registrations, 0);
      expect(tools.selected, isNull);
      expect(() => tools.select(mesh), throwsStateError);
    },
  );

  test(
    'picking rejects outside points and geometry outside camera clipping',
    () {
      expect(
        tools.pick(const ViewportPoint(100, 100), input.viewport)?.object,
        mesh,
      );
      expect(tools.pick(const ViewportPoint(-1, 100), input.viewport), isNull);
      engine.camera = PerspectiveCamera(far: 1);
      expect(tools.pick(const ViewportPoint(100, 100), input.viewport), isNull);
    },
  );

  test('snapped local transforms undo and redo exact prior poses', () {
    tools.transform(mesh, position: const Vec3(1.24, -.76, 0), grid: .5);
    expect(mesh.position, const Vec3(1, -1, 0));
    expect(tools.undo(), isTrue);
    expect(mesh.position, Vec3.zero);
    expect(tools.redo(), isTrue);
    expect(mesh.position, const Vec3(1, -1, 0));
    tools.transform(mesh, scale: const Vec3(2, 3, 4));
    tools.undo();
    expect(mesh.scale, Vec3.one);
    expect(mesh.position, const Vec3(1, -1, 0));
  });

  test('invalid transforms are rejected before any component changes', () {
    expect(
      () => tools.transform(
        mesh,
        position: const Vec3(2, 0, 0),
        scale: Vec3.zero,
      ),
      throwsArgumentError,
    );
    expect(mesh.position, Vec3.zero);
    expect(tools.canUndo, isFalse);
    expect(
      () => tools.transform(mesh, position: const Vec3(double.nan, 0, 0)),
      throwsArgumentError,
    );
    expect(() => tools.transform(mesh, grid: 0), throwsArgumentError);
    expect(
      () => tools.transform(mesh, rotation: const Quat(0, 0, 0, 0)),
      throwsArgumentError,
    );
  });

  test('undo refuses intervening edits and reparenting', () {
    tools.transform(mesh, position: const Vec3(1, 0, 0));
    mesh.position = const Vec3(2, 0, 0);
    expect(tools.undo, throwsStateError);
    expect(mesh.position, const Vec3(2, 0, 0));
    mesh.position = const Vec3(1, 0, 0);
    scene.add(Group()).add(mesh);
    expect(tools.undo, throwsStateError);
    expect(mesh.position, const Vec3(1, 0, 0));
  });

  test('history is bounded and new edits clear redo while no-ops do not', () {
    for (var i = 1; i <= 3; i++) {
      tools.transform(mesh, position: Vec3(i.toDouble(), 0, 0));
    }
    expect(tools.undo(), isTrue);
    expect(tools.undo(), isTrue);
    expect(tools.undo(), isFalse);
    expect(mesh.position, const Vec3(1, 0, 0));
    tools.transform(mesh, position: mesh.position);
    expect(tools.canRedo, isTrue);
    tools.transform(mesh, position: const Vec3(4, 0, 0));
    expect(tools.canRedo, isFalse);
  });

  test(
    'selection removal cleans highlight and foreign edits are rejected',
    () async {
      final original = mesh.material;
      tools.select(mesh);
      scene.remove(mesh);
      await Future<void>.delayed(Duration.zero);
      expect(tools.selected, isNull);
      expect(mesh.material, same(original));
      expect(() => tools.select(mesh), throwsArgumentError);
      expect(
        () => tools.transform(mesh, position: Vec3.one),
        throwsArgumentError,
      );
    },
  );

  test('measurements preserve world anchors and report scene units', () {
    final measurement = tools.measure(const Vec3(1, 2, 3), const Vec3(4, 6, 3));
    expect(measurement.distance, 5);
    expect(tools.measurements, [measurement]);
    expect(
      () => tools.measure(const Vec3(double.infinity, 0, 0), Vec3.zero),
      throwsArgumentError,
    );
    tools.clearMeasurements();
    expect(tools.measurements, isEmpty);
  });

  test('repeated undo and redo tolerate quaternion normalization rounding', () {
    mesh.quaternion = const Quat(.13, .37, .71, .23);
    tools.transform(mesh, rotation: const Quat(.17, .41, .53, .79));
    for (var i = 0; i < 30; i++) {
      expect(tools.undo(), isTrue);
      expect(tools.redo(), isTrue);
    }
  });

  test('a multi-update gesture commits one undo entry', () {
    final gesture = tools.beginTransform(mesh);
    for (var i = 1; i <= 20; i++) {
      gesture.update(position: Vec3(i / 10, 0, 0));
    }
    expect(tools.canUndo, isFalse);
    expect(tools.undo, throwsStateError);
    expect(() => tools.transform(mesh, scale: Vec3.one), throwsStateError);
    gesture.commit();
    expect(mesh.position, const Vec3(2, 0, 0));
    expect(tools.undo(), isTrue);
    expect(mesh.position, Vec3.zero);
    expect(tools.undo(), isFalse);
    expect(tools.redo(), isTrue);
    expect(mesh.position, const Vec3(2, 0, 0));
    expect(gesture.commit, throwsStateError);
  });

  test('cancel and no-op gestures preserve redo and restore exact pose', () {
    tools.transform(mesh, position: Vec3.one);
    tools.undo();
    final gesture = tools.beginTransform(mesh);
    gesture.update(position: const Vec3(3, 4, 5));
    expect(gesture.cancel(), isTrue);
    expect(mesh.position, Vec3.zero);
    expect(tools.canRedo, isTrue);
    tools.beginTransform(mesh).commit();
    expect(tools.canUndo, isFalse);
    expect(tools.canRedo, isTrue);
  });

  test(
    'external edits and changed ancestors end sessions without overwriting',
    () {
      final gesture = tools.beginTransform(mesh);
      gesture.update(position: Vec3.one);
      mesh.position = const Vec3(2, 3, 4);
      expect(gesture.commit, throwsStateError);
      expect(mesh.position, const Vec3(2, 3, 4));
      expect(gesture.isActive, isFalse);
      final parent = scene.add(Group());
      parent.add(mesh);
      final next = tools.beginTransform(mesh);
      next.update(position: Vec3.one);
      parent.position = Vec3.one;
      expect(next.cancel(), isFalse);
      expect(mesh.position, Vec3.one);
      expect(tools.canUndo, isFalse);
    },
  );

  test('selection, history handoff and detach cancel previews', () async {
    tools.select(mesh);
    tools.beginTransform(mesh).update(position: Vec3.one);
    tools.select(null);
    expect(mesh.position, Vec3.zero);
    tools.beginTransform(mesh).update(position: Vec3.one);
    tools.clearHistory();
    expect(mesh.position, Vec3.zero);
    tools.beginTransform(mesh).update(position: Vec3.one);
    await engine.dispose();
    expect(mesh.position, Vec3.zero);
  });

  test('helper picking leases compose and release independently', () {
    final first = tools.excludeFromPicking(mesh);
    final second = tools.excludeFromPicking(mesh);
    expect(tools.pick(const ViewportPoint(100, 100), input.viewport), isNull);
    first.dispose();
    expect(tools.pick(const ViewportPoint(100, 100), input.viewport), isNull);
    second.dispose();
    expect(
      tools.pick(const ViewportPoint(100, 100), input.viewport)!.object,
      same(mesh),
    );
  });
}
