import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'runtime_test.dart' as fixture;
import 'support/vehicle_fixture.dart' show buggyDefinition;
import 'package:zyren_game_native/animation.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import '../../../examples/game_lab/assets/skinned_character_asset.dart';

void main() {
  test(
    'native checkpoint restores airborne motion active gates and regenerated handles',
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
        final old = runtime.inputActor!,
            body = runtime.resolveBody(runtime.inputActor!)!;
        runtime.setEntityActive(
          runtime.simulation!.session.entities.entities
              .singleWhere((e) => e.handle.id == 'ground')
              .handle,
          false,
        );
        runtime.actions!.setAxis(deviceId: 'test', action: 'move.z', value: 1);
        runtime.simulation!.step();
        final save = runtime.save();
        final savedPosition = body.state.pose.position;
        final savedTick = runtime.tick;
        for (var i = 0; i < 10; i++) {
          runtime.simulation!.step();
        }
        final expected = body.state.pose.position;
        runtime.restore(GameSave.decode(save.encode()));
        expect(runtime.world, same(body.world));
        expect(runtime.tick, savedTick);
        expect(runtime.inputActor, isNot(old));
        expect(runtime.resolveBody(old), isNull);
        expect(runtime.resolveBody(runtime.inputActor!), same(body));
        expect(
          body.state.pose.position.distanceTo(savedPosition),
          lessThan(1e-6),
        );
        expect(runtime.objects['ground']!.visible, isFalse);
        expect(runtime.controlledActor, runtime.inputActor);
        runtime.actions!.setAxis(
          deviceId: 'replay',
          action: 'move.z',
          value: 1,
        );
        for (var i = 0; i < 10; i++) {
          runtime.simulation!.step();
        }
        expect(body.state.pose.position.distanceTo(expected), lessThan(1e-5));
        expect(
          () => runtime.simulation!.session.restore(save),
          throwsStateError,
        );
        final before = runtime.tick, pose = body.state.pose.position;
        final state = Map<String, Object?>.from(save.state);
        final native = Map<String, Object?>.from(
          state['game.native-level'] as Map,
        );
        native['bodies'] = {};
        state['game.native-level'] = native;
        expect(
          () => runtime.restore(save.copyForTest(state)),
          throwsFormatException,
        );
        expect(runtime.tick, before);
        expect(body.state.pose.position, pose);
      } finally {
        await engine?.dispose();
        await runtime.close();
      }
    },
  );
  test(
    'vehicle checkpoint preserves reverse gear suspension and paused possession',
    () async {
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
                GameEntityRecord(
                  id: 'buggy',
                  nodeId: 'buggy',
                  components: [
                    GameComponentRecord(
                      'game.collider',
                      1,
                      GameColliderDefinition(
                        motion: GameBodyMotion.dynamic,
                        halfExtents: const Vec3(.8, .25, 1.2),
                        mass: 400,
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
        project: project,
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
        for (var i = 0; i < 60; i++) {
          runtime.simulation!.step();
        }
        final actor = runtime.vehicles.keys.single;
        expect(runtime.controlEntity(actor), isTrue);
        runtime.actions!.setAxis(
          deviceId: 'drive',
          action: 'move.z',
          value: -1,
        );
        for (var i = 0; i < 30; i++) {
          runtime.simulation!.step();
        }
        runtime.pause();
        final saved = runtime.save(), body = runtime.resolveBody(actor)!;
        final handling = runtime.vehicles[actor]!.captureState(),
            pose = body.state.pose.position,
            velocity = body.state.velocity;
        runtime.resume();
        for (var i = 0; i < 20; i++) {
          runtime.simulation!.step();
        }
        runtime.restore(saved);
        final restored = runtime.vehicles.keys.single;
        expect(runtime.isPaused, isTrue);
        expect(runtime.controlledActor, restored);
        expect(runtime.resolveBody(restored), same(body));
        expect(body.state.pose.position.distanceTo(pose), lessThan(1e-6));
        expect(body.state.velocity.distanceTo(velocity), lessThan(1e-6));
        expect(runtime.vehicles[restored]!.captureState(), handling);
        expect(runtime.objects['buggy']!.children.length, 4);
        runtime.resume();
        expect(runtime.possession!.seatOf(runtime.inputActor!), 'buggy');
        final ticks = runtime.vehicles[restored]!.forceTicks;
        runtime.simulation!.step();
        expect(runtime.vehicles[restored]!.forceTicks, ticks + 1);
      } finally {
        await engine?.dispose();
        await runtime.close();
      }
    },
  );

  test(
    'imported motor checkpoint preserves root motion fade and airborne phase',
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
        final character = level.entities.last;
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
                    id: character.id,
                    nodeId: character.nodeId,
                    components: [
                      ...character.components,
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
        runtime.actions!.setAxis(deviceId: 'walk', action: 'move.z', value: 1);
        for (var i = 0; i < 3; i++) {
          runtime.simulation!.step();
        }
        final saved = runtime.save(),
            body = runtime.resolveBody(runtime.inputActor!)!;
        final motor = runtime.animatedCharacters.values.single.motor;
        final savedMotor = motor.captureState();
        for (var i = 0; i < 5; i++) {
          runtime.simulation!.step();
        }
        final expectedPose = body.state.pose.position,
            expectedMotor = motor.captureState();
        runtime.restore(saved);
        expect(runtime.animatedCharacters.values.single.motor, same(motor));
        expect(motor.captureState(), savedMotor);
        runtime.actions!.setAxis(
          deviceId: 'replay',
          action: 'move.z',
          value: 1,
        );
        for (var i = 0; i < 5; i++) {
          runtime.simulation!.step();
        }
        expect(
          body.state.pose.position.distanceTo(expectedPose),
          lessThan(1e-5),
        );
        expect(motor.captureState(), expectedMotor);
        expect(model.nodes[0]!.position.z, closeTo(0, 1e-5));
      } finally {
        await engine?.dispose();
        await runtime?.close();
        await assets.close();
      }
    },
  );

  test(
    'later codec failure rolls native mutations back before handles change',
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
        final failing = _FailingCodec();
        runtime.simulation!.session.registerStateCodec(failing);
        final saved = runtime.save();
        for (var i = 0; i < 5; i++) {
          runtime.simulation!.step();
        }
        final handle = runtime.inputActor!,
            body = runtime.resolveBody(runtime.inputActor!)!,
            tick = runtime.tick;
        final pose = body.state.pose.position;
        final bad = saved.copyForTest({
          ...saved.state,
          failing.id: {'fail': true},
        });
        expect(() => runtime.restore(bad), throwsStateError);
        expect(runtime.tick, tick);
        expect(runtime.inputActor, handle);
        expect(body.state.pose.position.distanceTo(pose), lessThan(1e-6));
        expect(runtime.error, isNull);
        runtime.simulation!.step();
        expect(runtime.tick, tick + 1);
      } finally {
        await engine?.dispose();
        await runtime.close();
      }
    },
  );

  test(
    'failed host rebind fails closed and still releases native resources',
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
        final saved = runtime.save();
        runtime.listenRestored(
          () => throw StateError('Host query rebind failed'),
        );
        expect(() => runtime.restore(saved), throwsStateError);
        expect(runtime.error, isNotNull);
        expect(runtime.simulation!.session.fault, isNotNull);
        expect(runtime.isPaused, isTrue);
        expect(runtime.resume, throwsStateError);
      } finally {
        await engine?.dispose();
        await runtime.close();
      }
    },
  );
}

extension on GameSave {
  GameSave copyForTest(Map<String, Object?> state) => GameSave(
    projectId: projectId,
    buildId: buildId,
    levelId: levelId,
    projectSchema: projectSchema,
    seed: seed,
    tick: tick,
    paused: paused,
    entities: entities,
    models: models,
    state: state,
    codecVersions: codecVersions,
  );
}

final class _FailingCodec extends GameStateCodec<bool> {
  @override
  String get id => 'test.later-codec';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) => {'fail': false};
  @override
  bool prepare(GameSession session, Map<String, Object?> data) =>
      data['fail'] as bool;
  @override
  void commit(GameSession session, bool prepared) {
    if (prepared) throw StateError('Later commit rejected');
  }
}
