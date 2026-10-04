import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'runtime_test.dart' as fixture;

void main() {
  test(
    'native primitive contact results have current tick and epoch lifetime',
    () async {
      final scene = Scene(), camera = PerspectiveCamera();
      final runtime = GameLevelRuntime(
        project: fixture.project(),
        scene: scene,
        camera: camera,
        objects: fixture.objects(scene),
      );
      SceneEngine? engine;
      try {
        await runtime.initialize();
        engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          rendererFactory: () async => fixture.RuntimeRenderer(),
          plugins: runtime.plugins,
        );
        runtime.simulation!.step();
        var actor = runtime.inputActor!;
        final wall = runtime.world!.createBody(
          kind: BodyKind.fixed,
          pose: PhysicsPose(position: const Vec3(0, 1, 2)),
        );
        final collider = wall.addCollider(const BoxShape(Vec3(1, 1, .1)));
        runtime.actions!.setAxis(
          deviceId: 'fixture',
          action: 'move.z',
          value: 1,
        );
        for (var i = 0; i < 80; i++) {
          runtime.simulation!.step();
        }
        final contacts = runtime.actorContacts(actor);
        expect(
          contacts.any((contact) => contact.collider == collider.id),
          isTrue,
        );
        expect(
          contacts.where((contact) => contact.collider == collider.id),
          everyElement(
            predicate<CharacterContact>(
              (contact) => contact.normal.y.abs() < .5,
            ),
          ),
        );
        expect(() => contacts.clear(), throwsUnsupportedError);
        runtime.pause();
        expect(runtime.actorContacts(actor), isEmpty);
        final saved = runtime.save(), previous = actor;
        runtime.restore(saved);
        actor = runtime.inputActor!;
        expect(runtime.actorContacts(previous), isEmpty);
        expect(runtime.actorContacts(actor), isEmpty);
        runtime.resume();
        expect(runtime.actorContacts(actor), isEmpty);
        runtime.simulation!.step();
        expect(runtime.actorContacts(actor), isNotEmpty);
        expect(
          runtime.respawnCharacterAt(
            actor,
            PhysicsPose(position: const Vec3(4, 2, -4)),
          ),
          isTrue,
        );
        expect(runtime.actorContacts(actor), isEmpty);
        expect(
          contacts.any((contact) => contact.collider == collider.id),
          isTrue,
        );
        runtime.simulation!.session.entities.despawn(actor);
        expect(runtime.actorContacts(actor), isEmpty);
      } finally {
        await engine?.dispose();
        await runtime.close();
      }
      expect(runtime.actorContacts(GameEntityHandle('player', 1)), isEmpty);
    },
  );
}
