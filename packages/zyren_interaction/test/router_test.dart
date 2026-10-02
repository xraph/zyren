import 'dart:async';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_interaction/zyren_interaction.dart';

void main() {
  late Scene scene;
  late Mesh mesh;
  late Camera camera;
  late ViewportMetrics viewport;
  late SceneInteractionRouter router;
  late List<ObjectPointerEvent> events;
  late List<Object> errors;
  setUp(() {
    scene = Scene();
    mesh = scene.add(Mesh(BoxGeometry(), UnlitMaterial(), name: 'Box'));
    camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
    viewport = const ViewportMetrics(200, 200);
    events = [];
    errors = [];
    router = SceneInteractionRouter(
      scene: scene,
      camera: () => camera,
      viewport: () => viewport,
      onError: (error, _) => errors.add(error),
    );
  });
  tearDown(() => router.dispose());
  ScenePointerEvent pointer(
    ScenePointerPhase phase, {
    double x = 100,
    double y = 100,
    int id = 1,
    ScenePointerKind kind = ScenePointerKind.mouse,
  }) => ScenePointerEvent(
    point: ViewportPoint(x, y),
    phase: phase,
    pointer: id,
    kind: kind,
  );
  void capture(ObjectPointerEvent event) {
    events.add(event);
    if (event.phase == ObjectPointerPhase.down) event.capturePointer();
  }

  List<ObjectPointerPhase> phases() => events.map((e) => e.phase).toList();

  test('nearest surface occludes registered objects behind it', () {
    router.register(mesh, events.add);
    final front = scene.add(Mesh(BoxGeometry(), UnlitMaterial()))
      ..position = const Vec3(0, 0, 2);
    router.dispatch(pointer(ScenePointerPhase.down));
    expect(events, isEmpty);
    front.visible = false;
    router.dispatch(pointer(ScenePointerPhase.down));
    expect(events.last.target, same(mesh));
    expect(events.last.hit.object, same(mesh));
    expect(events.last.hit.distance, closeTo(4.5, 1e-6));
  });
  test('child events bubble with stable target and can stop propagation', () {
    final group = scene.add(Object3D(name: 'Group'))..add(mesh);
    var stop = false;
    router.register(group, events.add);
    router.register(mesh, (event) {
      events.add(event);
      if (stop) event.stopPropagation();
    });
    router.dispatch(pointer(ScenePointerPhase.tap));
    expect(events.map((e) => e.currentTarget), [mesh, group]);
    expect(events.map((e) => e.target), everyElement(same(mesh)));
    events.clear();
    stop = true;
    router.dispatch(pointer(ScenePointerPhase.tap));
    expect(events.map((e) => e.currentTarget), [mesh]);
  });
  test('registered group receives descendant intersection identity', () {
    final group = scene.add(Object3D())..add(mesh);
    router.register(group, events.add);
    router.dispatch(pointer(ScenePointerPhase.tap));
    expect(events.single.target, same(group));
    expect(events.single.hit.object, same(mesh));
  });
  test(
    'hover transitions once, remains per pointer, and exit leaves capture',
    () {
      router.register(mesh, capture);
      router.dispatch(pointer(ScenePointerPhase.hover));
      router.dispatch(pointer(ScenePointerPhase.hover));
      router.dispatch(pointer(ScenePointerPhase.hover, id: 2));
      expect(
        phases().where((p) => p == ObjectPointerPhase.enter),
        hasLength(2),
      );
      router.clearHover(1);
      expect(router.hoveredObject(1), isNull);
      expect(router.hoveredObject(2), same(mesh));
      router.dispatch(pointer(ScenePointerPhase.down));
      router.clearHover();
      expect(router.capturedObject(1), same(mesh));
      expect(router.hoveredObject(2), isNull);
    },
  );
  test('capture retains outside move/up and then releases exactly once', () {
    router.register(mesh, capture);
    router.dispatch(pointer(ScenePointerPhase.down));
    router.dispatch(pointer(ScenePointerPhase.move, x: 250));
    expect(router.capturedObject(1), same(mesh));
    expect(events.last.phase, ObjectPointerPhase.move);
    expect(events.last.captured, isTrue);
    router.dispatch(pointer(ScenePointerPhase.up, x: 250));
    expect(phases().skip(phases().length - 2), [
      ObjectPointerPhase.up,
      ObjectPointerPhase.lostCapture,
    ]);
    expect(router.capturedObject(1), isNull);
    router.releasePointer(1);
    expect(
      phases().where((p) => p == ObjectPointerPhase.lostCapture),
      hasLength(1),
    );
    expect(
      () => events
          .firstWhere((e) => e.phase == ObjectPointerPhase.down)
          .capturePointer(),
      throwsStateError,
    );
  });
  test('touch up clears hover and two captures remain independent', () {
    router.register(mesh, capture);
    router.dispatch(
      pointer(ScenePointerPhase.down, kind: ScenePointerKind.touch),
    );
    router.dispatch(
      pointer(ScenePointerPhase.down, id: 2, kind: ScenePointerKind.touch),
    );
    router.dispatch(
      pointer(ScenePointerPhase.up, kind: ScenePointerKind.touch),
    );
    expect(router.capturedObject(1), isNull);
    expect(router.hoveredObject(1), isNull);
    expect(router.capturedObject(2), same(mesh));
    router.dispatch(pointer(ScenePointerPhase.cancel, id: 2));
    expect(phases().skip(phases().length - 3), [
      ObjectPointerPhase.cancel,
      ObjectPointerPhase.lostCapture,
      ObjectPointerPhase.leave,
    ]);
  });
  test(
    'removing captured ancestor cancels without another pointer event',
    () async {
      final group = scene.add(Object3D())..add(mesh);
      final registration = router.register(mesh, capture);
      router.dispatch(pointer(ScenePointerPhase.down));
      events.clear();
      scene.remove(group);
      await Future<void>.delayed(Duration.zero);
      expect(phases(), [
        ObjectPointerPhase.cancel,
        ObjectPointerPhase.lostCapture,
        ObjectPointerPhase.leave,
      ]);
      expect(router.capturedObject(1), isNull);
      expect(registration.isDisposed, isTrue);
      scene.add(group);
      router.dispatch(pointer(ScenePointerPhase.tap));
      expect(events, hasLength(3));
    },
  );
  test(
    'removing a picked child cancels capture owned by its surviving group',
    () async {
      final group = scene.add(Object3D())..add(mesh);
      router.register(group, capture);
      router.dispatch(pointer(ScenePointerPhase.down));
      group.remove(mesh);
      await Future<void>.delayed(Duration.zero);
      expect(router.capturedObject(1), isNull);
      expect(phases(), contains(ObjectPointerPhase.cancel));
    },
  );
  test(
    'reparenting a picked child releases its former group capture',
    () async {
      final group = scene.add(Object3D())..add(mesh);
      router.register(group, capture);
      router.dispatch(pointer(ScenePointerPhase.down));
      scene.add(mesh);
      await Future<void>.delayed(Duration.zero);
      expect(router.capturedObject(1), isNull);
      expect(router.hoveredObject(1), isNull);
      expect(phases(), contains(ObjectPointerPhase.cancel));
    },
  );
  test('reparenting during a callback skips the former ancestor', () {
    final group = scene.add(Object3D())..add(mesh);
    router.register(group, events.add);
    router.register(mesh, (event) {
      events.add(event);
      if (event.phase == ObjectPointerPhase.tap) scene.add(mesh);
    });
    router.dispatch(pointer(ScenePointerPhase.tap));
    expect(events.map((event) => event.currentTarget), [mesh]);
  });

  test('hiding an ancestor releases active capture', () async {
    final group = scene.add(Object3D())..add(mesh);
    router.register(mesh, capture);
    router.dispatch(pointer(ScenePointerPhase.down));
    group.visible = false;
    await Future<void>.delayed(Duration.zero);
    expect(router.capturedObject(1), isNull);
    expect(router.hoveredObject(1), isNull);
  });
  test('unregister during down prevents bubbling and stale capture', () {
    final group = scene.add(Object3D())..add(mesh);
    router.register(group, events.add);
    late Registration registration;
    registration = router.register(mesh, (event) {
      capture(event);
      if (event.phase == ObjectPointerPhase.down) registration.dispose();
    });
    router.dispatch(pointer(ScenePointerPhase.down));
    expect(events.map((e) => e.currentTarget), everyElement(same(mesh)));
    expect(router.capturedObject(1), isNull);
    expect(phases(), [
      ObjectPointerPhase.enter,
      ObjectPointerPhase.down,
      ObjectPointerPhase.gotCapture,
      ObjectPointerPhase.cancel,
      ObjectPointerPhase.lostCapture,
      ObjectPointerPhase.leave,
    ]);
  });
  test('capture transfer sends loss to child and gains capture on parent', () {
    final group = scene.add(Object3D())..add(mesh);
    router.register(group, capture);
    router.register(mesh, capture);
    router.dispatch(pointer(ScenePointerPhase.down));
    expect(router.capturedObject(1), same(group));
    expect(
      events
          .where((e) => e.phase == ObjectPointerPhase.lostCapture)
          .single
          .currentTarget,
      same(mesh),
    );
    router.releasePointer(1, owner: mesh);
    expect(router.capturedObject(1), same(group));
  });
  test(
    'dispose inside dispatch releases state and skips remaining handlers',
    () {
      final group = scene.add(Object3D())..add(mesh);
      router.register(group, events.add);
      router.register(mesh, (event) {
        capture(event);
        if (event.phase == ObjectPointerPhase.down) router.dispose();
      });
      router.dispatch(pointer(ScenePointerPhase.down));
      expect(router.isDisposed, isTrue);
      expect(router.capturedObject(1), isNull);
      expect(router.hoveredObject(1), isNull);
      expect(events.map((e) => e.currentTarget), everyElement(same(mesh)));
      expect(
        () => router.dispatch(pointer(ScenePointerPhase.tap)),
        throwsStateError,
      );
    },
  );
  test('handler failures are reported and terminal cleanup still runs', () {
    router.register(mesh, (event) {
      capture(event);
      if (event.phase == ObjectPointerPhase.up) {
        throw StateError('handler failure');
      }
    });
    router.dispatch(pointer(ScenePointerPhase.down));
    router.dispatch(pointer(ScenePointerPhase.up));
    expect(errors, hasLength(1));
    expect(router.capturedObject(1), isNull);
  });
  test(
    'invalid input is rejected, unusable viewport misses, camera getter is live',
    () {
      router.register(mesh, events.add);
      expect(
        () => router.dispatch(pointer(ScenePointerPhase.down, x: double.nan)),
        throwsArgumentError,
      );
      viewport = const ViewportMetrics(0, 0);
      router.dispatch(pointer(ScenePointerPhase.down));
      expect(events, isEmpty);
      viewport = const ViewportMetrics(200, 200, devicePixelRatio: 3);
      camera = PerspectiveCamera(position: const Vec3(0, 0, 5), far: 1);
      router.dispatch(pointer(ScenePointerPhase.down));
      expect(events, isEmpty);
      camera = PerspectiveCamera(position: const Vec3(0, 0, 5));
      router.dispatch(pointer(ScenePointerPhase.tap));
      expect(events.single.target, same(mesh));
    },
  );
  test('duplicate and foreign target registration fails', () {
    router.register(mesh, events.add);
    expect(() => router.register(mesh, events.add), throwsStateError);
    expect(() => router.register(Object3D(), events.add), throwsArgumentError);
  });
  test(
    'connection owns gestures and cancellation, and reconnect preserves handlers',
    () async {
      final input = TestInput();
      router.register(mesh, capture);
      final connection = router.connect(
        input,
        gestures: {SceneGesture.tap, SceneGesture.pointerDrag},
      );
      expect(input.interests, hasLength(2));
      expect(() => router.connect(input), throwsStateError);
      input.controller.add(pointer(ScenePointerPhase.down));
      connection.dispose();
      expect(input.interests, isEmpty);
      expect(router.capturedObject(1), isNull);
      expect(router.hoveredObject(1), isNull);
      final count = events.length;
      input.controller.add(pointer(ScenePointerPhase.down));
      expect(events, hasLength(count));
      router.connect(input);
      input.controller.add(pointer(ScenePointerPhase.tap));
      expect(events, hasLength(count + 1));
      router.dispose();
      expect(input.interests, isEmpty);
      await input.controller.close();
    },
  );
}

class TestInput implements ViewportInputSource {
  final controller = StreamController<ScenePointerEvent>.broadcast(sync: true);
  final interests = <SceneGesture>{};
  @override
  final viewport = const ViewportMetrics(200, 200);
  @override
  Stream<ScenePointerEvent> get events => controller.stream;
  @override
  Registration registerGesture(SceneGesture gesture) {
    interests.add(gesture);
    return Registration(() => interests.remove(gesture));
  }
}
