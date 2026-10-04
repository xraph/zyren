import 'dart:typed_data';
import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_lab/game_session.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

final class _Recipe implements ByteSourceResolver {
  final Uint8List bytes;
  _Recipe(String recipe) : bytes = Uint8List.fromList(utf8.encode(recipe));
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'offline exported games repeatedly release their native runtime before presentation',
    () async {
      for (final name in ['exploration', 'vehiclePlayground']) {
        final bytes = await File('games/$name.zygame').readAsBytes();
        for (var i = 0; i < 10; i++) {
          final game = await GameLabSession.load(bytes);
          final world = game.runtime.world!;
          expect(world.isClosed, isFalse);
          expect(game.scene.objects.containsKey('player'), isTrue);
          await game.close();
          await game.close();
          expect(world.isClosed, isTrue);
          expect(game.runtime.world, isNull);
        }
      }
    },
  );
  test('invalid bundle rejects before creating a game session', () async {
    await expectLater(
      GameLabSession.load(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<Exception>()),
    );
  });
  test(
    'model capacity rejects before resolving native scene or policy resources',
    () async {
      final registry = GameRegistry();
      registerGameComponentCodecs(registry);
      registerGameLevelCodecs(registry);
      registerGameAiCodecs(registry);
      final rules = GameRuleLibrary();
      registry.registerComponent(
        GameRuleComponentCodec(rules.actions, rules.predicates),
      );
      registry.registerComponent(
        GameStateMachineComponentCodec(rules.actions, rules.predicates),
      );
      final recipe = CompiledGameProject(
        project: GameProject(
          id: 'over-capacity',
          startupLevel: 'main',
          registry: registry,
          levels: [
            GameLevel(
              id: 'main',
              scene: GameSceneIdentity('scene', 'pin'),
              entities: [],
            ),
          ],
          // Deliberately unresolved pins establish that the size gate precedes
          // all model/scene loading rather than relying on their later failures.
          modelReferences: {for (var i = 0; i < 9; i++) 'model$i': {}},
        ),
      );
      final bundle = await PipelineBuilder(resolver: _Recipe(recipe.encode()))
          .build(
            entrySourceId: 'game.recipe',
            sources: [
              PipelineSource(
                sourceId: 'game.recipe',
                revision: recipe.buildId,
                uri: Uri.parse('game:///recipe'),
              ),
            ],
          );
      final before = const MlRuntime().diagnostics.liveSessions;
      await expectLater(
        GameLabSession.load(bundle.encode()),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('eight policies'),
          ),
        ),
      );
      expect(const MlRuntime().diagnostics.liveSessions, before);
    },
  );
}
