import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/animation.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'runtime_test.dart' as fixture;
import '../../../examples/game_lab/assets/skinned_character_asset.dart';

GameEntityRecord animated(
  GameEntityRecord original,
  String id, {
  String clip = 'walk',
}) => GameEntityRecord(
  id: id,
  nodeId: id,
  components: [
    ...original.components.where(
      (c) =>
          c.type != 'game.camera' && (id == 'player' || c.type != 'game.input'),
    ),
    GameComponentRecord(
      'game.character-rig',
      1,
      GameCharacterRigDefinition(rootMotionNode: 0, movingClip: clip).toJson(),
    ),
  ],
);

void main() {
  test(
    'two authored imported characters share an engine with independent motor clocks',
    () async {
      final assets = AssetScope(
        services: AssetServices(resolver: SkinnedCharacterSource()),
      );
      GameLevelRuntime? runtime;
      SceneEngine? engine;
      try {
        final source = await assets.load(Gltf.asset('skin.gltf')).result;
        final base = fixture.project(), baseLevel = base.project.levels.single;
        final actors = [
          animated(baseLevel.entities.last, 'player'),
          animated(baseLevel.entities.last, 'npc'),
        ];
        final compiled = CompiledGameProject(
          project: GameProject(
            id: 'two-characters',
            startupLevel: 'main',
            registry: base.project.registry,
            levels: [
              GameLevel(
                id: 'main',
                scene: baseLevel.scene,
                entities: [baseLevel.entities.first, ...actors],
              ),
            ],
          ),
        );
        final scene = Scene(), camera = PerspectiveCamera();
        final objects = fixture.objects(scene);
        final playerModel = source.instantiate(nativeDeformation: false);
        final npcModel = source.instantiate(nativeDeformation: false);
        objects['player']!.add(playerModel);
        objects['npc'] = scene.add(Group()..position = const Vec3(3, 1.5, 0));
        objects['npc']!.add(npcModel);
        runtime = GameLevelRuntime(
          project: compiled,
          scene: scene,
          camera: camera,
          objects: objects,
          animationFactory: createGameCharacterAnimation,
        );
        await runtime.initialize();
        expect(
          runtime.plugins.map((p) => p.id).toSet().length,
          runtime.plugins.length,
        );
        engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          rendererFactory: () async => fixture.RuntimeRenderer(),
          plugins: runtime.plugins,
        );
        runtime.simulation!.step();
        expect(runtime.animatedCharacters.length, 2);
        runtime.actions!.setAxis(deviceId: 'test', action: 'move.z', value: 1);
        final npc = runtime.animatedCharacters.entries.singleWhere(
          (e) => e.key.id == 'npc',
        );
        final before = npc.value.motor.character.positionOf('walk');
        for (var i = 0; i < 60; i++) {
          runtime.simulation!.step();
        }
        expect(
          runtime.resolveBody(runtime.inputActor!)!.state.pose.position.z,
          greaterThan(.1),
        );
        expect(
          runtime.resolveBody(npc.key)!.state.pose.position.z,
          closeTo(0, .001),
        );
        expect(npc.value.motor.character.positionOf('walk'), before);
        expect(playerModel.position.y, -.8);
        expect(
          playerModel.nodes[0]!.position.z,
          closeTo(0, .00001),
          reason: 'Root translation reaches physics only once.',
        );
      } finally {
        await engine?.dispose();
        await runtime?.close();
        await assets.close();
      }
    },
  );

  test(
    'invalid imported clip fails before model mutation and a corrected mapping retries',
    () async {
      final assets = AssetScope(
        services: AssetServices(resolver: SkinnedCharacterSource()),
      );
      final world = PhysicsWorld();
      SceneEngine? engine;
      try {
        final model = (await assets.load(Gltf.asset('skin.gltf')).result)
            .instantiate(nativeDeformation: false);
        final root = Group()..add(model);
        final scene = Scene()..add(root);
        final body = world.createBody(kind: BodyKind.kinematicPosition);
        final collider = body.addCollider(
          const CapsuleShape(halfHeight: .5, radius: .3),
        );
        final original = fixture.project().project.levels.single.entities.last;
        expect(
          () => createGameCharacterAnimation(
            animated(original, 'player', clip: 'missing'),
            root,
            body,
            collider,
          ),
          throwsA(
            isA<StateError>().having(
              (e) => e.toString(),
              'diagnostic',
              contains('Available clips: walk'),
            ),
          ),
        );
        expect(model.position, Vec3.zero);
        final good = createGameCharacterAnimation(
          animated(original, 'player'),
          root,
          body,
          collider,
        )!;
        engine = await SceneEngine.create(
          scene: scene,
          camera: PerspectiveCamera(),
          rendererFactory: () async => fixture.RuntimeRenderer(),
          plugins: good.plugins,
        );
        expect(good.motor.character.isAttached, isTrue);
      } finally {
        await engine?.dispose();
        world.close();
        await assets.close();
      }
    },
  );
}
