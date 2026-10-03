import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'support/character_fixture.dart';

void main() {
  test(
    'camera and query factories consume the shared authored definitions',
    () async {
      final f = await GameCharacterFixture.create();
      addTearDown(f.close);
      final cameraDefinition = GameCameraDefinition(
        mode: GameCameraMode.firstPerson,
        target: f.controller.actor.id,
        radius: .2,
        eyeHeight: .7,
        thirdPersonDistance: 5,
        vehicleDistance: 9,
      );
      final camera = PerspectiveCamera();
      final rig = GameCameraRig.fromDefinition(
        camera: camera,
        session: f.simulation.session,
        world: f.world,
        resolveBody: f.motors.resolveBody,
        definition: cameraDefinition,
      );
      expect(rig.actor, f.controller.actor);
      expect(rig.radius, .2);
      expect(rig.eyeHeight, .7);
      expect(rig.thirdPersonDistance, 5);
      expect(rig.vehicleDistance, 9);
      expect(rig.update(const CharacterIntent()), isTrue);
      expect(
        camera.position.y,
        closeTo(f.body.state.pose.position.y + .7, 1e-6),
      );
      expect(
        () => GameCameraRig.fromDefinition(
          camera: camera,
          session: f.simulation.session,
          world: f.world,
          resolveBody: f.motors.resolveBody,
          definition: GameCameraDefinition(target: 'absent'),
        ),
        throwsStateError,
      );
      final router = SceneInteractionRouter(
        scene: f.scene,
        camera: () => camera,
        viewport: () => const ViewportMetrics(328, 700),
      );
      addTearDown(router.dispose);
      final target = f.simulation.session.entities.spawn('target');
      final targetBody = f.box(const Vec3(0, .81, 1), const Vec3(.2, .2, .2));
      final definition = GameInteractionDefinition(
        id: 'use',
        label: 'Use',
        target: target.id,
        reach: 1.5,
        maxCandidates: 2,
        maxTargets: 3,
      );
      final query = InteractionQuery.fromDefinition(
        session: f.simulation.session,
        world: f.world,
        router: router,
        resolveBody: (actor) =>
            actor == f.controller.actor ? f.body : targetBody,
        definition: definition,
      );
      addTearDown(query.close);
      var executed = false;
      query.register(
        target: target,
        object: f.scene.add(Group()),
        body: targetBody,
        id: definition.id,
        label: definition.label,
        onExecute: (_) => executed = true,
      );
      expect(query.reach, 1.5);
      expect(query.maxCandidates, 2);
      expect(query.maxTargets, 3);
      expect(
        query.execute(
          f.controller.actor,
          query.available(f.controller.actor).single,
        ),
        isTrue,
      );
      expect(executed, isTrue);
    },
  );
}
