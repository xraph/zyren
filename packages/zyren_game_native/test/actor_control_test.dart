import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'runtime_test.dart' as fixture;
import 'support/vehicle_fixture.dart' show buggyDefinition;
import 'animation_test.dart' show animated;
import 'package:zyren_game_native/animation.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_physics/zyren_physics.dart';
import '../../../examples/game_lab/assets/skinned_character_asset.dart';

class Decisions extends GameSystem {
  final GameLevelRuntime runtime;
  GameRuntimeActorControl? control;
  Decisions(this.runtime);
  @override
  String get id => 'test.actor-decisions';
  @override
  GamePhase get phase => GamePhase.decisions;
  @override
  void fixedUpdate(GameSession session) {
    final npc = session.entities.entities
        .singleWhere((e) => e.handle.id == 'npc')
        .handle;
    control ??= runtime.acquireActorControl(npc);
    control!.applyCharacter(const CharacterIntent(moveZ: 1));
  }
}

void main() {
  test(
    'decisions drive primitive NPC on the same physics tick with exclusive epoch leases',
    () async {
      final base = fixture.project(),
          level = base.project.levels.single,
          player = base.project.levels.single.entities.last;
      final compiled = CompiledGameProject(
        project: GameProject(
          id: base.project.id,
          startupLevel: 'main',
          registry: base.project.registry,
          levels: [
            GameLevel(
              id: 'main',
              scene: level.scene,
              entities: [
                ...level.entities,
                GameEntityRecord(
                  id: 'npc',
                  nodeId: 'npc',
                  components: player.components
                      .where(
                        (c) =>
                            c.type != 'game.input' && c.type != 'game.camera',
                      )
                      .toList(),
                ),
              ],
            ),
          ],
        ),
      );
      final scene = Scene(),
          camera = PerspectiveCamera(),
          objects = fixture.objects(scene);
      objects['npc'] = scene.add(Group()..position = const Vec3(2, 1.5, 0));
      late GameLevelRuntime runtime;
      late Decisions decisions;
      runtime = GameLevelRuntime(
        project: compiled,
        scene: scene,
        camera: camera,
        objects: objects,
        systemFactory: (_) => [decisions = Decisions(runtime)],
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
        final npc = decisions.control!.actor;
        expect(
          runtime.resolveBody(npc)!.state.pose.position.z,
          greaterThan(.05),
        );
        expect(runtime.actorGrounded(npc), isNotNull);
        expect(runtime.resolveCollider(npc), isNotNull);
        expect(runtime.acquireActorControl(runtime.inputActor!), isNull);
        expect(runtime.acquireActorControl(npc), isNull);
        final previous = decisions.control!;
        runtime.pause();
        expect(previous.isActive, isFalse);
        expect(
          () => previous.applyCharacter(const CharacterIntent(moveZ: 1)),
          throwsStateError,
        );
        runtime.resume();
        final fresh = runtime.acquireActorControl(npc)!;
        expect(fresh.generation, greaterThan(previous.generation));
        expect(runtime.controlEntity(npc), isTrue);
        expect(fresh.isActive, isFalse);
        expect(
          () => fresh.applyCharacter(const CharacterIntent(moveX: 1)),
          throwsStateError,
        );
        expect(runtime.acquireActorControl(npc), isNull);
        final checkpoint = runtime.save();
        runtime.restore(checkpoint);
        expect(runtime.resolveCollider(npc), isNull);
        expect(runtime.actorGrounded(npc), isNull);
      } finally {
        await engine?.dispose();
        await runtime.close();
      }
    },
  );

  test(
    'vehicle NPC lease feeds the existing controller without a second step',
    () async {
      final base = fixture.project(), level = base.project.levels.single;
      final compiled = CompiledGameProject(
        project: GameProject(
          id: base.project.id,
          startupLevel: 'main',
          registry: base.project.registry,
          levels: [
            GameLevel(
              id: 'main',
              scene: level.scene,
              entities: [
                ...level.entities,
                GameEntityRecord(
                  id: 'buggy',
                  nodeId: 'buggy',
                  components: [
                    GameComponentRecord(
                      'game.collider',
                      1,
                      GameColliderDefinition(
                        motion: GameBodyMotion.dynamic,
                        mass: 400,
                        halfExtents: const Vec3(.8, .25, 1.2),
                      ).toJson(),
                    ),
                    GameComponentRecord(
                      'game.vehicle',
                      1,
                      buggyDefinition().toJson(),
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
      objects['buggy'] = scene.add(Group()..position = const Vec3(2, .8, 0));
      final runtime = GameLevelRuntime(
        project: compiled,
        scene: scene,
        camera: camera,
        objects: objects,
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
        for (var i = 0; i < 90; i++) {
          runtime.simulation!.step();
        }
        final actor = runtime.vehicles.keys.single;
        final control = runtime.acquireActorControl(actor)!;
        final body = runtime.resolveBody(actor)!;
        body.teleport(PhysicsPose(position: const Vec3(10, .8, 0)));
        expect(runtime.controlEntity(actor), isFalse);
        expect(control.isActive, isTrue);
        body.teleport(PhysicsPose(position: const Vec3(2, .8, 0)));
        control.applyVehicle(const VehicleIntent(throttle: 1));
        final ticks = runtime.vehicles[actor]!.forceTicks;
        for (var i = 0; i < 30; i++) {
          runtime.simulation!.step();
        }
        expect(runtime.vehicles[actor]!.forceTicks, ticks + 30);
        expect(runtime.resolveBody(actor)!.state.velocity.z, greaterThan(1));
        control.dispose();
        expect(control.isActive, isFalse);
        runtime.simulation!.step();
        expect(runtime.vehicles[actor]!.telemetry.appliedIntent.brake, 1);
      } finally {
        await engine?.dispose();
        await runtime.close();
      }
    },
  );
  test(
    'animated NPC lease retains the authored motor and releases on deactivation',
    () async {
      final assets = AssetScope(
        services: AssetServices(resolver: SkinnedCharacterSource()),
      );
      GameLevelRuntime? runtime;
      SceneEngine? engine;
      try {
        final model = (await assets.load(Gltf.asset('skin.gltf')).result)
            .instantiate(nativeDeformation: false);
        final base = fixture.project(), level = base.project.levels.single;
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
                  ...level.entities,
                  animated(level.entities.last, 'npc'),
                ],
              ),
            ],
          ),
        );
        final scene = Scene(),
            camera = PerspectiveCamera(),
            objects = fixture.objects(scene);
        objects['npc'] = scene.add(
          Group()
            ..position = const Vec3(2, 1.5, 0)
            ..add(model),
        );
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
        final actor = runtime.animatedCharacters.keys.single,
            controller = runtime.animatedCharacters.values.single;
        final control = runtime.acquireActorControl(actor)!;
        control.applyCharacter(const CharacterIntent(moveZ: 1));
        final ticks = controller.motorTicks;
        for (var i = 0; i < 20; i++) {
          runtime.simulation!.step();
        }
        expect(controller.motorTicks, ticks + 20);
        expect(
          runtime.resolveBody(actor)!.state.pose.position.z,
          greaterThan(.1),
        );
        expect(model.nodes[0]!.position.z, closeTo(0, 1e-5));
        runtime.setEntityActive(actor, false);
        expect(runtime.isEntityActive(actor), isFalse);
        expect(control.isActive, isFalse);
        expect(runtime.acquireActorControl(actor), isNull);
        expect(
          () => control.applyCharacter(const CharacterIntent(moveX: 1)),
          throwsStateError,
        );
        runtime.setEntityActive(actor, true);
        expect(runtime.isEntityActive(actor), isTrue);
        final fresh = runtime.acquireActorControl(actor)!;
        expect(fresh.generation, greaterThan(control.generation));
        runtime.simulation!.session.entities.despawn(actor);
        expect(runtime.isEntityActive(actor), isFalse);
        expect(fresh.isActive, isFalse);
        expect(runtime.resolveCollider(actor), isNull);
        expect(() => runtime!.save(), throwsFormatException);
      } finally {
        await engine?.dispose();
        await runtime?.close();
        await assets.close();
      }
    },
  );
}
