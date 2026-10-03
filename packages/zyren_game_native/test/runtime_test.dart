import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';

final class RuntimeRenderer implements SceneRenderer {
  @override
  final capabilities = RendererCapabilities(
    name: 'runtime-lifetime',
    features: {RenderFeatures.indexedMeshes, RenderFeature.portablePrimitives},
    maxDimension: 128,
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

CompiledGameProject project() {
  final registry = GameRegistry();
  registerGameComponentCodecs(registry);
  registerGameLevelCodecs(registry);
  return CompiledGameProject(
    project: GameProject(
      id: 'native-runtime',
      startupLevel: 'main',
      registry: registry,
      levels: [
        GameLevel(
          id: 'main',
          scene: GameSceneIdentity('runtime', 'fixture'),
          entities: [
            GameEntityRecord(
              id: 'ground',
              nodeId: 'ground',
              components: [
                GameComponentRecord(
                  'game.collider',
                  1,
                  GameColliderDefinition(
                    halfExtents: const Vec3(10, .5, 10),
                  ).toJson(),
                ),
              ],
            ),
            GameEntityRecord(
              id: 'player',
              nodeId: 'player',
              components: [
                GameComponentRecord(
                  'game.collider',
                  1,
                  GameColliderDefinition(
                    shape: GameColliderShape.capsule,
                    motion: GameBodyMotion.kinematic,
                  ).toJson(),
                ),
                GameComponentRecord(
                  'game.character',
                  1,
                  GameCharacterDefinition().toJson(),
                ),
                GameComponentRecord(
                  'game.input',
                  1,
                  GameInputMap(
                    actions: [
                      GameActionDefinition('move.x'),
                      GameActionDefinition('move.z'),
                      GameActionDefinition('jump', button: true),
                    ],
                    bindings: [],
                  ).toJson(),
                ),
                GameComponentRecord(
                  'game.camera',
                  1,
                  GameCameraDefinition(target: 'player').toJson(),
                ),
              ],
            ),
          ],
        ),
      ],
    ),
  );
}

Map<String, Object3D> objects(Scene scene) => {
  'ground': scene.add(Group()..position = const Vec3(0, -.5, 0)),
  'player': scene.add(Group()..position = const Vec3(0, 1.5, 0)),
};

class PauseAtStart extends GameSystem {
  @override
  String get id => 'a.pause-at-start';
  @override
  GamePhase get phase => GamePhase.commands;
  @override
  void start(GameSession session) => session.pause();
  @override
  void fixedUpdate(GameSession session) {}
}

void main() {
  test(
    'shared native runtime moves a character and closes leases after physics',
    () async {
      final scene = Scene(), camera = PerspectiveCamera();
      final closed = <String>[];
      late GameLevelRuntime runtime;
      runtime = GameLevelRuntime(
        project: project(),
        scene: scene,
        camera: camera,
        objects: objects(scene),
        resources: [
          GameRuntimeResourceLease(
            close: () {
              expect(runtime.world, isNull);
              closed.add('assets');
            },
          ),
          GameRuntimeResourceLease(
            close: () => closed.add('model'),
            pause: () => closed.add('pause'),
            resume: () => closed.add('resume'),
          ),
        ],
      );
      await runtime.initialize();
      expect(runtime.resourcesAdopted, isTrue);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        rendererFactory: () async => RuntimeRenderer(),
        plugins: runtime.plugins,
      );
      final world = runtime.world!;
      runtime.simulation!.step();
      final actor = runtime.inputActor!;
      runtime.actions!.setAxis(deviceId: 'fixture', action: 'move.z', value: 1);
      for (var i = 0; i < 10; i++) {
        runtime.simulation!.step();
      }
      expect(
        runtime.resolveBody(actor)!.state.pose.position.z,
        greaterThan(.1),
      );
      runtime.pause();
      final tick = runtime.tick;
      runtime.step();
      expect(runtime.tick, tick + 1);
      expect(runtime.isPaused, isTrue);
      runtime.resume();
      expect(runtime.controlledActor, actor);
      expect(closed, ['pause', 'resume', 'pause', 'resume']);
      await engine.dispose();
      await runtime.close();
      await runtime.close();
      expect(world.isClosed, isTrue);
      expect(closed.sublist(closed.length - 2), ['model', 'assets']);
    },
  );
  test(
    'leases follow a pause during partial startup and resume deferred systems',
    () async {
      final scene = Scene(), camera = PerspectiveCamera();
      var paused = false;
      final runtime = GameLevelRuntime(
        project: project(),
        scene: scene,
        camera: camera,
        objects: objects(scene),
        systemFactory: (_) => [PauseAtStart()],
        resources: [
          GameRuntimeResourceLease(
            close: () {},
            pause: () => paused = true,
            resume: () => paused = false,
          ),
        ],
      );
      await runtime.initialize();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        rendererFactory: () async => RuntimeRenderer(),
        plugins: runtime.plugins,
      );
      runtime.simulation!.step();
      expect(runtime.isPaused, isTrue);
      expect(paused, isTrue);
      runtime.resume();
      expect(paused, isFalse);
      runtime.simulation!.step();
      expect(runtime.inputActor, isNotNull);
      await engine.dispose();
      await runtime.close();
    },
  );
  test('resource hook failure invalidates work and remains closable', () async {
    final scene = Scene(), camera = PerspectiveCamera();
    var retired = 0, queued = 0;
    final runtime = GameLevelRuntime(
      project: project(),
      scene: scene,
      camera: camera,
      objects: objects(scene),
      resources: [
        GameRuntimeResourceLease(
          close: () => retired++,
          pause: () => throw StateError('audio pause failed'),
        ),
      ],
    );
    await runtime.initialize();
    final engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => RuntimeRenderer(),
      plugins: runtime.plugins,
    );
    runtime.simulation!.step();
    final session = runtime.simulation!.session, world = runtime.world!;
    session.enqueueMutation((_) => queued++);
    expect(runtime.pause, throwsStateError);
    expect(session.paused, isTrue);
    expect(session.fault, isNotNull);
    expect(() => session.step(), throwsStateError);
    expect(queued, 0);
    await engine.dispose();
    await runtime.close();
    expect(world.isClosed, isTrue);
    expect(retired, 1);
  });
  test(
    'failed adoption closes transferred leases and preserves an existing scene owner',
    () async {
      final scene = Scene(),
          camera = PerspectiveCamera(),
          values = objects(Scene());
      values['player']!.scale = const Vec3(-1, 1, 1);
      final closed = <int>[];
      final failed = GameLevelRuntime(
        project: project(),
        scene: scene,
        camera: camera,
        objects: values,
        resources: [
          GameRuntimeResourceLease(close: () => closed.add(1)),
          GameRuntimeResourceLease(close: () => closed.add(2)),
        ],
      );
      await expectLater(failed.initialize(), throwsStateError);
      expect(failed.resourcesAdopted, isTrue);
      expect(failed.world, isNull);
      expect(closed, [2, 1]);
      await failed.close();
      expect(closed, [2, 1]);
      final retained = GameRuntimeResourceLease(close: () => closed.add(4));
      final good = GameLevelRuntime(
        project: project(),
        scene: scene,
        camera: camera,
        objects: objects(scene),
        resources: [retained],
      );
      await good.initialize();
      final foreign = GameLevelRuntime(
        project: project(),
        scene: scene,
        camera: camera,
        objects: good.objects,
        resources: [GameRuntimeResourceLease(close: () => closed.add(3))],
      );
      await expectLater(foreign.initialize(), throwsStateError);
      expect(foreign.resourcesAdopted, isFalse);
      expect(closed, [2, 1]);
      await foreign.close();
      expect(good.world!.isClosed, isFalse);
      final otherScene = Scene();
      final reused = GameLevelRuntime(
        project: project(),
        scene: otherScene,
        camera: PerspectiveCamera(),
        objects: objects(otherScene),
        resources: [retained],
      );
      await expectLater(reused.initialize(), throwsArgumentError);
      expect(reused.resourcesAdopted, isFalse);
      await reused.close();
      expect(closed, [2, 1]);
      expect(good.world!.isClosed, isFalse);
      await good.close();
      expect(closed, [2, 1, 4]);
    },
  );
}
