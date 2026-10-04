import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/animation.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_physics/zyren_physics.dart';
import '../../../examples/game_lab/assets/skinned_character_asset.dart';
import 'runtime_test.dart' as fixture;

void main() {
  test(
    'animated respawn invalidates old control, resets falling and preserves animation phase without drift',
    () async {
      final counts = PhysicsWorld.nativeCounts;
      final assets = AssetScope(
        services: AssetServices(resolver: SkinnedCharacterSource()),
      );
      SceneEngine? engine;
      GameLevelRuntime? runtime;
      try {
        final model = (await assets.load(Gltf.asset('skin.gltf')).result)
            .instantiate(nativeDeformation: false);
        final base = fixture.project(),
            level = base.project.levels.single,
            actor = level.entities.last;
        final project = CompiledGameProject(
          project: GameProject(
            id: base.project.id,
            startupLevel: 'main',
            registry: base.project.registry,
            levels: [
              GameLevel(
                id: 'main',
                scene: level.scene,
                entities: [
                  level.entities.first,
                  GameEntityRecord(
                    id: actor.id,
                    nodeId: actor.nodeId,
                    components: [
                      ...actor.components.where((c) => c.type != 'game.input'),
                      GameComponentRecord(
                        'game.character-rig',
                        1,
                        GameCharacterRigDefinition(
                          rootMotionNode: 0,
                          movingClip: 'walk',
                        ).toJson(),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        );
        final scene = Scene(),
            camera = PerspectiveCamera(),
            objects = fixture.objects(scene);
        objects['player']!.add(model);
        runtime = GameLevelRuntime(
          project: project,
          scene: scene,
          camera: camera,
          objects: objects,
          animationFactory: createGameCharacterAnimation,
        );
        await runtime.initialize();
        engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          rendererFactory: () async => fixture.RuntimeRenderer(),
          plugins: runtime.plugins,
        );
        runtime.simulation!.step();
        final handle = runtime.animatedCharacters.keys.single,
            character = runtime.animatedCharacters.values.single,
            old = runtime.acquireActorControl(handle)!;
        old.applyCharacter(const CharacterIntent(moveZ: 1));
        for (var i = 0; i < 4; i++) {
          runtime.simulation!.step();
        }
        final phase = character.motor.captureState()['animation'];
        final body = runtime.resolveBody(handle)!,
            collider = runtime.resolveCollider(handle)!;
        final beforeTick = runtime.tick, mass = body.state.mass;
        expect(
          runtime.respawnCharacterAt(
            handle,
            PhysicsPose(position: const Vec3(4, 2, -4)),
          ),
          isTrue,
        );
        expect(runtime.tick, beforeTick);
        expect(old.isActive, isFalse);
        expect(
          () => old.applyCharacter(const CharacterIntent(moveZ: 1)),
          throwsStateError,
        );
        expect(character.motor.captureState()['animation'], phase);
        expect(character.motor.captureState()['verticalSpeed'], 0);
        expect(character.grounded, isFalse);
        expect(runtime.resolveBody(handle), same(body));
        expect(runtime.resolveCollider(handle), same(collider));
        expect(body.state.mass, mass);
        expect(body.state.velocity, Vec3.zero);
        expect(body.state.angularVelocity, Vec3.zero);
        expect(runtime.actorContacts(handle), isEmpty);
        final fresh = runtime.acquireActorControl(handle)!;
        fresh.applyCharacter(const CharacterIntent());
        for (var i = 0; i < 40; i++) {
          runtime.simulation!.step();
        }
        expect(body.state.pose.position.x, closeTo(4, 1e-5));
        expect(body.state.pose.position.z, closeTo(-4, 1e-5));
        expect(character.grounded, isTrue);
        expect(runtime.actorContacts(handle), isNotEmpty);
        fresh.dispose();
      } finally {
        await engine?.dispose();
        await runtime?.close();
        await assets.close();
      }
      expect(PhysicsWorld.nativeCounts, counts);
    },
  );
}
