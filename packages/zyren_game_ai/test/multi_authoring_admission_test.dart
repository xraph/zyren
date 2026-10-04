import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/runtime.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_ml/zyren_ml.dart';

void main() {
  test(
    'multi task cannot silently launch through structured runtime',
    () async {
      final registry = GameRegistry();
      registerGameComponentCodecs(registry);
      registerGameLevelCodecs(registry);
      registerGameAiCodecs(registry);
      final project = CompiledGameProject(
        project: GameProject(
          id: 'multi-admission',
          startupLevel: 'arena',
          registry: registry,
          levels: [
            GameLevel(
              id: 'arena',
              scene: GameSceneIdentity('arena', '1'),
              entities: [
                GameEntityRecord(
                  id: 'pursuer',
                  nodeId: 'pursuer',
                  components: [
                    GameComponentRecord(
                      'game.character',
                      1,
                      GameCharacterDefinition(maxSpeed: 2).toJson(),
                    ),
                    GameComponentRecord('game.ai', 1, {
                      'profile': 'guard',
                      'brain': 'scripted',
                      'multiTask': 'competitive-pursuit',
                      'multiRole': 'pursuer',
                      'teamId': 'pursuit',
                    }),
                  ],
                ),
              ],
            ),
          ],
        ),
        systemVersions: {},
        fixedHz: 50,
      );
      final runtime = GameLevelRuntime(
        project: project,
        scene: Scene(),
        camera: PerspectiveCamera(),
        objects: {},
      );
      var resolved = 0;
      final cache = MlModelCache(
        resolver: (_) async {
          resolved++;
          throw StateError('Models must not load for an unsupported task.');
        },
      );
      final ai = GameLevelAi(
        runtime: () => runtime,
        cache: cache,
        policies: {},
      );
      try {
        await expectLater(ai.warmup(), throwsA(isA<UnsupportedError>()));
        expect(ai.actors, isEmpty);
        expect(resolved, 0);
        expect(runtime.world, isNull);
      } finally {
        await ai.close();
        await runtime.close();
      }
    },
  );
}
