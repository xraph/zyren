import 'dart:async';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

class OrbitInput implements ViewportInputSource {
  final bus = StreamController<ScenePointerEvent>.broadcast(sync: true);
  final interests = <SceneGesture, int>{};
  @override
  ViewportMetrics get viewport => ViewportMetrics(logicalWidth, logicalHeight);
  double logicalWidth = 300;
  double logicalHeight = 200;
  @override
  Stream<ScenePointerEvent> get events => bus.stream;
  @override
  Registration registerGesture(SceneGesture gesture) {
    interests.update(gesture, (n) => n + 1, ifAbsent: () => 1);
    return Registration(() => interests[gesture] = interests[gesture]! - 1);
  }

  void send(
    ScenePointerPhase phase, {
    double x = 0,
    double y = 0,
    double scale = 1,
    int count = 1,
    int buttons = 1,
    Set<SceneModifier> modifiers = const {},
  }) => bus.add(
    ScenePointerEvent(
      point: const ViewportPoint(100, 100),
      phase: phase,
      delta: ViewportPoint(x, y),
      scale: scale,
      pointerCount: count,
      buttons: buttons,
      modifiers: modifiers,
    ),
  );
}

class Harness {
  final OrbitNavigation controls;
  final input = OrbitInput();
  late SceneEngine engine;
  int demands = 0;
  Harness(this.controls);
  Future<void> start([Camera? camera, Scene? scene]) async {
    engine = await SceneEngine.create(
      scene: scene ?? Scene(),
      camera: camera ?? PerspectiveCamera(),
      plugins: [controls],
      input: input,
      rendererFactory: () async => TestRenderer([]),
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
  }

  Future<void> tick(int ms) async => engine.render(
    elapsed: Duration.zero,
    time: FrameTime(
      elapsed: Duration.zero,
      delta: Duration(milliseconds: ms),
    ),
    width: 4,
    height: 4,
  );
  Future<void> close() async {
    await engine.dispose();
    await input.bus.close();
  }
}

void closeVector(Vec3 actual, Vec3 expected, [double tolerance = 1e-8]) =>
    expect(actual.distanceTo(expected), lessThan(tolerance));

void main() {
  test('shared scenes retain independent view controls and input', () async {
    final scene = Scene();
    final first = Harness(OrbitNavigation(damping: Duration.zero));
    final second = Harness(OrbitNavigation(damping: Duration.zero));
    await first.start(null, scene);
    await second.start(null, scene);
    try {
      first.input.send(ScenePointerPhase.scaleStart);
      first.input.send(ScenePointerPhase.scaleUpdate, x: 30);
      first.input.send(ScenePointerPhase.scaleEnd);
      expect(first.engine.camera.position.x, lessThan(0));
      expect(second.engine.camera.position, const Vec3(0, 0, 5));
      expect(second.demands, 0);
      await first.engine.dispose();
      second.controls.zoomBy(2);
      closeVector(second.engine.camera.position, const Vec3(0, 0, 10));
    } finally {
      await first.close();
      await second.close();
    }
  });

  test(
    'custom drag bindings and zero extents preserve the input contract',
    () async {
      final h = Harness(
        OrbitNavigation(
          damping: Duration.zero,
          dragBinding: (_) => OrbitDragAction.none,
        ),
      );
      await h.start();
      try {
        h.input.send(ScenePointerPhase.scaleStart);
        h.input.send(ScenePointerPhase.scaleUpdate, x: 50, y: 20);
        expect(h.engine.camera.position, const Vec3(0, 0, 5));
        h.input.logicalHeight = 0;
        h.input.send(ScenePointerPhase.scaleUpdate, scale: 2);
        expect(h.controls.isInteracting, isFalse);
        expect(h.demands, 0);
        expect(h.engine.camera.position, const Vec3(0, 0, 5));
        expect(() => OrbitLimits(minDistance: 0), throwsArgumentError);
        expect(() => OrbitLimits(maxDistance: double.nan), throwsArgumentError);
        expect(() => OrbitLimits(maxPolarAngle: math.pi), throwsArgumentError);
        expect(
          () => OrbitNavigation(damping: const Duration(microseconds: -1)),
          throwsArgumentError,
        );
      } finally {
        await h.close();
      }
    },
  );
  test(
    'unrepresentable pole updates leave the previous camera intact',
    () async {
      final h = Harness(
        OrbitNavigation(
          damping: Duration.zero,
          limits: OrbitLimits(minPolarAngle: 1e-12),
        ),
      );
      await h.start();
      try {
        final revision = h.engine.camera.revision;
        expect(() => h.controls.rotateBy(polar: -10), throwsArgumentError);
        expect(h.engine.camera.revision, revision);
        expect(h.controls.isSettling, isFalse);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'programmatic orbit preserves arbitrary up, pan and both projection zooms',
    () async {
      final h = Harness(OrbitNavigation(damping: Duration.zero));
      await h.start(PerspectiveCamera(position: const Vec3(0, 0, 5)));
      try {
        h.controls.rotateBy(azimuth: math.pi / 2);
        closeVector(h.engine.camera.position, const Vec3(5, 0, 0));
        h.controls.panBy(const Vec3(1, 2, 3));
        closeVector(h.engine.camera.target, const Vec3(1, 2, 3));
        h.controls.zoomBy(2);
        closeVector(h.engine.camera.position, const Vec3(11, 2, 3));
        expect(h.demands, 0);
        h.engine.camera = OrthographicCamera(
          position: const Vec3(5, 0, 0),
          up: const Vec3(0, 0, 1),
          zoom: 2,
        );
        h.controls.rotateBy(azimuth: math.pi / 2);
        closeVector(h.engine.camera.position, const Vec3(0, 5, 0));
        h.controls.zoomBy(2);
        expect((h.engine.camera as OrthographicCamera).zoom, 1);
        closeVector(h.engine.camera.position, const Vec3(0, 5, 0));
      } finally {
        await h.close();
      }
    },
  );
  test(
    'limits clamp poles, distance and zoom without singular view matrices',
    () async {
      final h = Harness(
        OrbitNavigation(
          damping: Duration.zero,
          limits: OrbitLimits(
            minDistance: 2,
            maxDistance: 8,
            minZoom: .5,
            maxZoom: 4,
            minPolarAngle: .2,
            maxPolarAngle: 2.5,
          ),
        ),
      );
      await h.start();
      try {
        h.controls.rotateBy(polar: -100);
        expect(
          (h.engine.camera.position.normalized()).y,
          closeTo(math.cos(.2), 1e-12),
        );
        h.controls.zoomBy(.0001);
        expect(h.engine.camera.position.length, closeTo(2, 1e-12));
        h.controls.zoomBy(1e10);
        expect(h.engine.camera.position.length, closeTo(8, 1e-12));
        h.controls.rotateBy(polar: 100);
        expect(
          h.engine.camera.position.normalized().y,
          closeTo(math.cos(2.5), 1e-12),
        );
        h.engine.camera.viewProjection(1);
        h.engine.camera = OrthographicCamera();
        h.controls.zoomBy(1e8);
        expect((h.engine.camera as OrthographicCamera).zoom, .5);
        h.controls.zoomBy(1e-8);
        expect((h.engine.camera as OrthographicCamera).zoom, 4);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'won gestures use logical extent and incremental pinch ratios',
    () async {
      final h = Harness(OrbitNavigation(damping: Duration.zero));
      await h.start(PerspectiveCamera(fieldOfView: math.pi / 2));
      try {
        h.input.send(ScenePointerPhase.move, x: 50);
        expect(h.engine.camera.position, const Vec3(0, 0, 5));
        h.input.send(ScenePointerPhase.scaleStart);
        h.input.send(ScenePointerPhase.scaleUpdate, x: 50);
        closeVector(h.engine.camera.position, const Vec3(-5, 0, 0));
        h.input.send(ScenePointerPhase.scaleEnd);
        h.controls.reset();
        h.input.send(ScenePointerPhase.scaleStart, count: 2);
        h.input.send(ScenePointerPhase.scaleUpdate, x: 20, count: 2, scale: 2);
        closeVector(h.engine.camera.target, const Vec3(-1, 0, 0));
        expect(
          h.engine.camera.position.distanceTo(h.engine.camera.target),
          closeTo(2.5, 1e-12),
        );
        h.input.send(ScenePointerPhase.scaleUpdate, count: 2, scale: 4);
        expect(
          h.engine.camera.position.distanceTo(h.engine.camera.target),
          closeTo(1.25, 1e-12),
        );
        h.input.send(ScenePointerPhase.scaleEnd);
        expect(h.demands, 0);
      } finally {
        await h.close();
      }
    },
  );
  test('damping is time based and eventually releases frame demand', () async {
    Future<Vec3> sample(int ms, int count) async {
      final h = Harness(
        OrbitNavigation(damping: const Duration(milliseconds: 120)),
      );
      await h.start();
      try {
        h.controls.rotateBy(azimuth: 1);
        expect(h.demands, 1);
        await h.tick(5000);
        expect(
          h.engine.camera.position,
          const Vec3(0, 0, 5),
          reason: 'Do not integrate idle time.',
        );
        for (var i = 0; i < count; i++) {
          await h.tick(ms);
        }
        final value = h.engine.camera.position;
        for (var i = 0; i < 100; i++) {
          await h.tick(20);
        }
        expect(h.demands, 0);
        closeVector(
          h.engine.camera.position,
          Vec3(5 * math.sin(1), 0, 5 * math.cos(1)),
          1e-7,
        );
        return value;
      } finally {
        await h.close();
      }
    }

    closeVector(await sample(20, 25), await sample(50, 10));
  });
  test(
    'cancel, disable and camera replacement discard queued motion',
    () async {
      final h = Harness(OrbitNavigation());
      await h.start();
      try {
        h.input.send(ScenePointerPhase.scaleStart);
        h.input.send(ScenePointerPhase.scaleUpdate, x: 20);
        expect(h.demands, 1);
        h.input.send(ScenePointerPhase.cancel);
        await h.tick(30);
        expect(h.demands, 0);
        expect(h.engine.camera.position, const Vec3(0, 0, 5));
        h.controls.rotateBy(azimuth: 1);
        h.controls.enabled = false;
        expect(h.input.interests.values.every((n) => n == 0), isTrue);
        expect(h.demands, 0);
        h.controls.enabled = true;
        h.controls.rotateBy(azimuth: 1);
        final other = PerspectiveCamera(position: const Vec3(1, 2, 3));
        h.engine.camera = other;
        await h.tick(50);
        expect(other.position, const Vec3(1, 2, 3));
        expect(h.demands, 0);
        h.controls.rotateBy(azimuth: 1);
        other.position = const Vec3(3, 4, 5);
        await h.tick(50);
        expect(other.position, const Vec3(3, 4, 5));
        expect(h.demands, 0);
      } finally {
        await h.close();
      }
      expect(h.demands, 0);
      expect(h.input.interests.values.every((n) => n == 0), isTrue);
    },
  );
  test(
    'save/reset restores projection settings and invalid input is atomic',
    () async {
      final h = Harness(OrbitNavigation(damping: Duration.zero));
      final camera = OrthographicCamera(zoom: 2, verticalSize: 3, near: .1);
      await h.start(camera);
      try {
        h.controls.panBy(const Vec3(2, 3, 4));
        h.controls.saveState();
        final position = camera.position;
        camera.frameBounds(
          Bounds3(const Vec3(-20, -20, -20), const Vec3(20, 20, 20)),
          aspect: 1,
        );
        h.controls.reset();
        expect(camera.position, position);
        expect(camera.target, const Vec3(2, 3, 4));
        expect(camera.zoom, 2);
        expect(camera.verticalSize, 3);
        expect(camera.near, .1);
        expect(camera.far, 1000);
        final revision = camera.revision;
        expect(
          () => h.controls.rotateBy(azimuth: double.nan),
          throwsArgumentError,
        );
        expect(
          () => h.controls.panBy(const Vec3(double.infinity, 0, 0)),
          throwsArgumentError,
        );
        expect(() => h.controls.zoomBy(0), throwsArgumentError);
        expect(camera.revision, revision);
      } finally {
        await h.close();
      }
    },
  );
  test(
    'failed shared attachment leaves the first view controls intact',
    () async {
      final controls = OrbitNavigation();
      final h = Harness(controls);
      await h.start();
      try {
        final other = Harness(controls);
        await expectLater(other.start(), throwsStateError);
        await other.input.bus.close();
        controls.rotateBy(azimuth: 1);
        expect(h.demands, 1);
        await h.tick(0);
        await h.tick(20);
        expect(h.engine.camera.position.x, greaterThan(0));
      } finally {
        await h.close();
      }
    },
  );
}
