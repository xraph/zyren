import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';
import 'animation_test.dart' show movement;

void main() {
  test(
    'transitions ignore idle deltas and keep held poses scheduled',
    () async {
      final node = Group();
      final mixer = AnimationMixer(nodes: {'part': node});
      final action = mixer.play(movement())
        ..seek(const Duration(milliseconds: 500))
        ..pause();
      var demands = 0;
      Future<SceneEngine> attach() => SceneEngine.create(
        scene: Scene()..add(node),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [mixer],
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      Future<void> frame(SceneEngine engine, int ms) => engine
          .render(
            elapsed: Duration(milliseconds: ms),
            time: FrameTime(
              elapsed: Duration(milliseconds: ms),
              delta: Duration(milliseconds: ms),
            ),
            width: 4,
            height: 4,
          )
          .then((_) {});
      var engine = await attach();
      try {
        await frame(engine, 0);
        action.fadeOut(const Duration(seconds: 1));
        action.warpTo(0, const Duration(seconds: 1));
        expect(demands, 1);
        await frame(engine, 10000);
        expect(action.weight, 1);
        expect(action.speed, 1);
        await frame(engine, 250);
        expect(action.weight, .75);
        expect(action.speed, .75);
        expect(action.timeSeconds, .5);
        await engine.dispose();
        expect(demands, 0);
        engine = await attach();
        await frame(engine, 10000);
        expect(action.weight, .75);
        expect(action.speed, .75);
        await frame(engine, 750);
        expect(action.weight, 0);
        expect(action.speed, 0);
        expect(demands, 0);
        action.speed = 1;
        action.resume();
        await frame(engine, 10000);
        action.fadeTo(1, const Duration(seconds: 1));
        await frame(engine, 250);
        expect(
          action.timeSeconds,
          .75,
          reason: 'Starting a fade preserves a running clock.',
        );
        expect(
          action.weight,
          0,
          reason: 'Only the new transition skips its first delta.',
        );
        await frame(engine, 250);
        expect(action.weight, .25);
      } finally {
        await engine.dispose();
      }
      expect(demands, 0);
    },
  );

  test(
    'finite completion releases demand before events can start a successor',
    () async {
      final system = AnimationSystem(),
          mixer = AnimationMixer(nodes: {'part': Group()});
      var demands = 0;
      final registration = system.add(mixer);
      final action = mixer.play(movement(), repetitions: 2);
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [system],
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      AnimationAction? successor;
      final sub = mixer.events.listen((event) {
        if (event is AnimationFinishedEvent) {
          expect(demands, 0);
          successor = mixer.play(movement());
          expect(demands, 1);
        }
      });
      try {
        await engine.render(elapsed: Duration.zero, width: 4, height: 4);
        await engine.render(
          elapsed: const Duration(seconds: 2),
          time: const FrameTime(
            elapsed: Duration(seconds: 2),
            delta: Duration(seconds: 2),
          ),
          width: 4,
          height: 4,
        );
        await Future<void>.delayed(Duration.zero);
        expect(action.isFinished, isTrue);
        expect(successor, isNotNull);
        registration.dispose();
        expect(demands, 0);
      } finally {
        await sub.cancel();
        registration.dispose();
        await engine.dispose();
      }
    },
  );

  test('failed direct attachment cannot steal a system-owned mixer', () async {
    final system = AnimationSystem();
    final mixer = AnimationMixer(nodes: {'part': Group()});
    final action = mixer.play(movement());
    final registration = system.add(mixer);
    var demands = 0;
    Future<SceneEngine> create(List<ScenePlugin> plugins) => SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      rendererFactory: () async => TestRenderer([]),
      plugins: plugins,
      acquireFrameDemand: () {
        demands++;
        return Registration(() => demands--);
      },
    );
    final engine = await create([system]);
    try {
      await expectLater(create([mixer]), throwsStateError);
      expect(demands, 1);
      action.pause();
      expect(demands, 0);
      action.resume();
      expect(demands, 1);
    } finally {
      registration.dispose();
      await engine.dispose();
    }
    expect(demands, 0);
  });

  test(
    'dynamic systems own late mixers and release demand on removal',
    () async {
      final system = AnimationSystem(), other = AnimationSystem();
      var demands = 0;
      final engine = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [system],
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      final mixer = AnimationMixer(nodes: {'part': Group()});
      final action = mixer.play(movement());
      final registration = system.add(mixer);
      expect(demands, 1);
      expect(() => other.add(mixer), throwsStateError);
      expect(() => system.add(mixer), throwsStateError);
      Future<void> step() async {
        await engine.render(
          elapsed: const Duration(milliseconds: 200),
          time: const FrameTime(
            elapsed: Duration(milliseconds: 200),
            delta: Duration(milliseconds: 200),
          ),
          width: 4,
          height: 4,
        );
      }

      await step();
      expect(action.timeSeconds, 0);
      await step();
      expect(action.timeSeconds, .2);
      registration.dispose();
      expect(demands, 0);
      await step();
      expect(action.timeSeconds, .2);
      final retained = other.add(mixer);
      await engine.dispose();
      final next = await SceneEngine.create(
        scene: Scene(),
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [other],
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      expect(demands, 1);
      await next.dispose();
      expect(demands, 0);
      retained.dispose();
      mixer.update(const Duration(milliseconds: 100));
      expect(action.timeSeconds, closeTo(.3, 1e-9));
    },
  );

  test(
    'pause, finish, speed zero and detach release demand; resume ignores idle time',
    () async {
      final node = Group(), scene = Scene();
      scene.add(node);
      final mixer = AnimationMixer(nodes: {'part': node});
      final action = mixer.play(movement(), loop: AnimationLoop.once);
      var demands = 0, invalidations = 0;
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [mixer],
        onInvalidate: () => invalidations++,
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      Future<void> frame(int ms, int deltaMs) async {
        await engine.render(
          elapsed: Duration(milliseconds: ms),
          time: FrameTime(
            elapsed: Duration(milliseconds: ms),
            delta: Duration(milliseconds: deltaMs),
          ),
          width: 4,
          height: 4,
        );
      }

      try {
        expect(demands, 1);
        await frame(10000, 10000);
        expect(action.timeSeconds, 0);
        action
            .resume(); // Resuming an already running action must not skip a step.
        await frame(10250, 250);
        expect(node.position.x, 2.5);
        action.pause();
        expect(demands, 0);
        await frame(30000, 19750);
        expect(node.position.x, 2.5);
        action.resume();
        expect(demands, 1);
        await frame(50000, 20000);
        expect(node.position.x, 2.5);
        await frame(50250, 250);
        expect(node.position.x, 5);
        action.speed = 0;
        expect(demands, 0);
        action.speed = 1;
        expect(demands, 1);
        await frame(90000, 39750);
        expect(node.position.x, 5);
        await frame(90500, 500);
        expect(node.position.x, 10);
        expect(action.isFinished, isTrue);
        expect(demands, 0);
        action.seek(const Duration(milliseconds: 300));
        expect(node.position.x, 3);
        expect(action.isPaused, isTrue);
        expect(demands, 0);
        action.resume();
        expect(demands, 1);
        expect(invalidations, greaterThan(0));
      } finally {
        await engine.dispose();
      }
      expect(demands, 0);
      mixer.update(const Duration(milliseconds: 100));
      expect(node.position.x, 4);
      action.stop();
      expect(node.position, Vec3.zero);
    },
  );
  test(
    'starting a second action does not skip the first action clock',
    () async {
      final a = Group(), b = Group(), scene = Scene();
      scene
        ..add(a)
        ..add(b);
      final mixer = AnimationMixer(nodes: {'part': a, 'second': b});
      final first = mixer.play(movement());
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [mixer],
      );
      try {
        await engine.render(elapsed: Duration.zero, width: 4, height: 4);
        final second = mixer.play(
          AnimationClip(
            tracks: [
              VectorKeyframeTrack.position(
                target: 'second',
                times: [0, 1],
                values: [Vec3.zero, Vec3.one],
              ),
            ],
          ),
        );
        await engine.render(
          elapsed: const Duration(milliseconds: 100),
          time: const FrameTime(
            elapsed: Duration(milliseconds: 100),
            delta: Duration(milliseconds: 100),
          ),
          width: 4,
          height: 4,
        );
        expect(first.timeSeconds, .1);
        expect(second.timeSeconds, 0);
      } finally {
        await engine.dispose();
      }
    },
  );
}
