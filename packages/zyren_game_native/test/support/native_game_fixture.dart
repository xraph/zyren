import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';

CompiledGameProject testProject({int fixedHz = 60}) => CompiledGameProject(
  project: GameProject(
    id: 'fixture',
    startupLevel: 'level',
    levels: [
      GameLevel(
        id: 'level',
        scene: GameSceneIdentity('scene', 'pin'),
        entities: [],
      ),
    ],
    registry: GameRegistry(),
  ),
  fixedHz: fixedHz,
);

// Physics is native; the renderer is a deterministic presentation test double.
class FixtureRenderer implements SceneRenderer {
  @override
  final capabilities = RendererCapabilities(
    name: 'fixture',
    features: {
      RenderFeatures.indexedMeshes,
      RenderFeatures.rgbaReadback,
      RenderFeature.portablePrimitives,
    },
    maxDimension: 1024,
  );
  @override
  Future<RenderedFrame> render(
    Scene scene,
    Camera camera, {
    required int width,
    required int height,
  }) async => RenderedFrame(Uint8List(width * height * 4), width, height);
  @override
  Future<void> dispose() async {}
}

class NativeGameFixture {
  final PhysicsWorld world;
  final PhysicsBody body;
  final GameSimulation simulation;
  final SceneEngine engine;
  final int Function() _steps;
  int get physicsSteps => _steps();
  NativeGameFixture._(
    this.world,
    this.body,
    this.simulation,
    this.engine,
    this._steps,
  );
  static Future<NativeGameFixture> create({
    bool realtime = true,
    InputSource? input,
  }) async {
    final world = PhysicsWorld(gravity: Vec3.zero);
    final body = world.createBody(velocity: const Vec3(1, 0, 0));
    body.addCollider(const SphereShape(.1));
    var steps = 0;
    final physics = PhysicsPlugin(
      world: world,
      externallyDriven: true,
      interpolate: false,
      beforeStep: (_) => steps++,
    );
    final simulation = GameSimulation(
      project: testProject(),
      seed: 7,
      physics: physics,
      ownsWorld: true,
    );
    final scene = Scene();
    physics.bind(scene.add(Group()), body);
    final engine = await SceneEngine.create(
      scene: scene,
      camera: PerspectiveCamera(),
      input: input,
      rendererFactory: () async => FixtureRenderer(),
      plugins: [
        physics,
        GameScenePlugin(simulation, realtime: realtime),
      ],
    );
    return NativeGameFixture._(world, body, simulation, engine, () => steps);
  }

  Future<void> renderOneFrame(Duration elapsed) async {
    await engine.render(elapsed: elapsed, width: 8, height: 8);
  }

  Future<void> close() async {
    await engine.dispose();
    await simulation.close();
  }
}
