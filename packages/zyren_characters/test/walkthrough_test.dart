import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';
import '../example/walkthrough_scene.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test(
    'native Rapier capsule follows a queried route with imported animation',
    () async {
      final before = PhysicsWorld.nativeCounts;
      final demo = await WalkthroughScene.load();
      final engine = await SceneEngine.create(
        scene: demo.scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: [demo.timeline, demo.character],
      );
      try {
        await engine.render(
          elapsed: Duration.zero,
          time: const FrameTime(delta: Duration.zero),
          width: 8,
          height: 8,
        );
        var animated = false;
        for (var i = 0; i < 250; i++) {
          demo.advance();
          await engine.render(
            elapsed: Duration.zero,
            time: const FrameTime(delta: WalkthroughScene.step),
            width: 8,
            height: 8,
          );
          animated |= demo.model.nodes[3]!.quaternion.x.abs() > .05;
          expect(
            (demo.root.position - demo.body.state.pose.position).length,
            lessThan(1e-6),
          );
          expect(demo.model.position, Vec3.zero);
        }
        expect(animated, isTrue);
        expect(demo.arrived, isTrue);
        expect(
          (demo.root.position -
                  (demo.route.points.last + WalkthroughScene.offset))
              .length,
          lessThan(1e-5),
        );
        expect(demo.character.currentState, 'idle');
        expect(demo.character.weights['walk'], 0);
        expect(demo.physics.droppedSeconds, 0);
        final hit = demo.world.rayCast(
          origin: demo.root.position + const Vec3(0, 3, 0),
          direction: const Vec3(0, -1, 0),
        );
        expect(hit?.body, demo.body.id);
        demo.root.position = Vec3.zero;
        expect(() => demo.physics.advance(.02), throwsStateError);
      } finally {
        await engine.dispose();
        await demo.close();
      }
      expect(PhysicsWorld.nativeCounts, before);
    },
  );
}
