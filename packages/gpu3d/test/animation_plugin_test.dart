import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';
import 'animation_test.dart' show movement;

void main() {
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
