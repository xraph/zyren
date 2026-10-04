import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../../zyren_game_native/test/runtime_test.dart' as base;

final class VisualRuntimeFixture {
  final scene = Scene(), camera = PerspectiveCamera();
  final profile = TrainingVisualProfiles.forFamily(
    family: 'guard',
    mode: 'depth',
  );
  late final GameLevelRuntime runtime;
  late final GameLevelAi ai;
  SceneEngine? engine;
  VisualRuntimeFixture({
    Future<RenderBackend> Function()? backend,
    int actorCount = 1,
    bool learned = false,
    GameVisualRuntimeLimits limits = const GameVisualRuntimeLimits(
      deadline: Duration(milliseconds: 20),
    ),
  }) {
    final registry = GameRegistry();
    registerGameComponentCodecs(registry);
    registerGameLevelCodecs(registry);
    registerGameAiCodecs(registry);
    final level = base.project().levels.single;
    final model = MlModelManifest.decode(
      File('test/fixtures/visual_runtime_probe.json').readAsStringSync(),
    );
    final project = CompiledGameProject(
      fixedHz: 50,
      project: GameProject(
        id: 'visual-probe',
        startupLevel: 'main',
        registry: registry,
        levels: [
          GameLevel(
            id: 'main',
            scene: level.scene,
            entities: [
              ...level.entities,
              for (var i = 0; i < actorCount; i++)
                GameEntityRecord(
                  id: 'npc$i',
                  nodeId: 'npc$i',
                  components: [
                    ...level.entities.last.components.where(
                      (c) => c.type != 'game.input' && c.type != 'game.camera',
                    ),
                    GameComponentRecord('game.ai', 1, {
                      'profile': 'guard',
                      'cameraMode': 'depth',
                      'brain': learned ? 'learned' : 'scripted',
                      if (learned) 'modelHash': model.sha256,
                    }),
                  ],
                ),
            ],
          ),
        ],
      ),
    );
    final objects = base.objects(scene);
    for (var i = 0; i < actorCount; i++) {
      objects['npc$i'] = scene.add(Group()..position = Vec3(i * 2.0, 1.5, 0));
    }
    scene.add(
      Mesh(
        BoxGeometry(width: 3, height: 3, depth: 1),
        UnlitMaterial(color: const Color3(1, 0, 0)),
      )..position = const Vec3(0, 1.5, 4),
    );
    ai = GameLevelAi(
      runtime: () => runtime,
      cache: MlModelCache(
        resolver: (_) =>
            File('test/fixtures/visual_runtime_probe.onnx').readAsBytes(),
      ),
      openCameraBackend: backend == null ? null : (_, _) => backend(),
      visualLimits: limits,
      policies: {
        if (learned)
          model.sha256: GameRuntimePolicy(
            contract: PolicyContract(
              model: model,
              observation: profile.spec,
              decoder: profile.decoder,
              encoder: VisualPolicyEncoder(profile),
              continuousOutput: null,
              discreteOutput: 'logits',
              maxHoldTicks: 2,
            ),
            fixedHz: 50,
            evaluationHash: '0' * 64,
          ),
      },
    );
    runtime = GameLevelRuntime(
      project: project,
      scene: scene,
      camera: camera,
      objects: objects,
      systemFactory: (_) => ai.systems,
    );
  }
  Future<void> start() async {
    await runtime.initialize();
    await ai.warmup();
    engine = await SceneEngine.create(
      scene: scene,
      camera: camera,
      rendererFactory: () async => base.RuntimeRenderer(),
      plugins: runtime.plugins,
    );
    runtime.simulation!.step();
  }

  Future<void> step() async {
    runtime.simulation!.step();
    await ai.flush();
  }

  Future<void> close() async {
    await engine?.dispose();
    await ai.close();
    await runtime.close();
  }
}
