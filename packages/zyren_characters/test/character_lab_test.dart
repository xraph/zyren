import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_physics/zyren_physics.dart';
// Keep the example fixture outside the package dependency graph.
// ignore: avoid_relative_lib_imports
import '../example/app/lib/character_lab_scene.dart';
import '../../zyren/test/support/fakes.dart';

void main() {
  test(
    'root-motion character replans around a live collider, arrives and releases',
    () async {
      final before = PhysicsWorld.nativeCounts;
      final lab = await CharacterLabScene.load(nativeDeformation: false);
      final engine = await SceneEngine.create(
        scene: lab.scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TestRenderer([]),
        plugins: lab.plugins,
      );
      try {
        Future<void> tick() => engine.render(
          elapsed: Duration.zero,
          time: const FrameTime(delta: CharacterLabScene.step),
          width: 8,
          height: 8,
        );
        for (var i = 0; i < 30; i++) {
          await tick();
        }
        lab.setObstacle(true);
        for (var i = 0; i < 700 && !lab.arrived; i++) {
          await tick();
          final p = lab.feet;
          expect(
            p.x < 2.3 || p.x > 3.7 || p.z < 2.3 || p.z > 3.7,
            isTrue,
            reason: 'capsule clearance at $p',
          );
          expect(lab.model.nodes[0]!.position, Vec3.zero);
        }
        expect(
          lab.arrived,
          isTrue,
          reason: 'feet=${lab.feet} status=${lab.follower.route?.status}',
        );
        expect(lab.follower.replans, greaterThanOrEqualTo(2));
        await tick();
        expect(lab.character.currentState, 'idle');
        final pose = lab.actor.position,
            clock = lab.character.positionOf('walk');
        lab.setPaused(true);
        for (var i = 0; i < 5; i++) {
          await tick();
        }
        expect(lab.actor.position, pose);
        expect(lab.character.positionOf('walk'), clock);
        lab.setPaused(false);
        lab.setGoal(const Vec3(1, 0, 1));
        await tick();
        expect(lab.character.currentState, 'walk');
        lab.removeCharacter();
        await tick();
        expect(lab.body.isAlive, isFalse);
      } finally {
        await engine.dispose();
        await lab.close();
      }
      expect(PhysicsWorld.nativeCounts, before);
    },
  );
}
