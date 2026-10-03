import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'support/character_fixture.dart';

void main() {
  test(
    'camera modes follow the actor and sweep around native obstruction',
    () async {
      final f = await GameCharacterFixture.create();
      try {
        f.box(const Vec3(0, 1, -2), const Vec3(3, 2, .1));
        final camera = PerspectiveCamera();
        final rig = GameCameraRig(
          camera: camera,
          session: f.simulation.session,
          world: f.world,
          resolveBody: f.motors.resolveBody,
        );
        rig.follow(f.controller.actor);
        expect(rig.update(const CharacterIntent()), isTrue);
        expect(camera.position.z, greaterThan(-1.8));
        expect(camera.position.z, lessThan(-1));
        for (final width in [1280.0, 396.0, 328.0]) {
          expect(
            camera.viewProjection(width / 700).storage.every((v) => v.isFinite),
            isTrue,
          );
        }
        rig.mode = GameCameraMode.firstPerson;
        rig.update(const CharacterIntent(lookYaw: 1, lookPitch: .2));
        expect(camera.position.x, closeTo(f.body.state.pose.position.x, .001));
        expect(camera.target.distanceTo(camera.position), closeTo(1, .001));
        rig.mode = GameCameraMode.vehicle;
        rig.update(const CharacterIntent());
        expect(camera.position.z, greaterThan(-1.8));
        final start = camera.position;
        final track = rig.trackToActor(
          const Duration(milliseconds: 200),
          intent: const CharacterIntent(lookYaw: 1),
        );
        track.prepare(Duration.zero)();
        expect(camera.position, start);
        track.prepare(const Duration(milliseconds: 200))();
        expect(camera.position, isNot(start));
        final last = camera.position;
        f.simulation.session.entities.despawn(f.controller.actor);
        expect(rig.update(const CharacterIntent()), isFalse);
        expect(camera.position, last);
        expect(rig.actor, isNull);
      } finally {
        await f.close();
      }
    },
  );
  test('camera rejects stale follow targets and invalid constraints', () async {
    final f = await GameCharacterFixture.create();
    try {
      expect(
        () => GameCameraRig(
          camera: PerspectiveCamera(),
          session: f.simulation.session,
          world: f.world,
          resolveBody: f.motors.resolveBody,
          radius: 0,
        ),
        throwsArgumentError,
      );
      final rig = GameCameraRig(
        camera: PerspectiveCamera(),
        session: f.simulation.session,
        world: f.world,
        resolveBody: f.motors.resolveBody,
      );
      final actor = f.controller.actor;
      f.simulation.session.entities.despawn(actor);
      f.simulation.session.entities.spawn(actor.id);
      expect(() => rig.follow(actor), throwsStateError);
    } finally {
      await f.close();
    }
  });
}
