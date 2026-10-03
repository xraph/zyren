import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/scene.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';
import '../../../examples/game_lab/assets/skinned_character_asset.dart';

void main() {
  test(
    'compiled asset scenes reopen from offline Pipeline without Studio asset services',
    () async {
      final uri = Uri.parse('game:///skin.gltf');
      final source = await PipelineBuilder(resolver: SkinnedCharacterSource())
          .build(
            entrySourceId: 'skin',
            sources: [
              PipelineSource(sourceId: 'skin', revision: '1', uri: uri),
            ],
          );
      final authoring = createGameDevelopmentAuthoring();
      final document = authoring.initialize(
        StudioDocument(
          id: 'export',
          title: 'Asset export',
          nodes: [
            StudioNode(
              id: 'model',
              label: 'Model',
              kind: StudioNodeKind.asset,
              assetId: 'character',
            ),
          ],
          assets: [
            StudioAsset(
              id: 'character',
              label: 'Character',
              provider: 'zyren.pipeline',
              reference: PipelineAssetReference.fromBundle(source).toJson(),
            ),
          ],
        ),
        levelId: 'main',
      );
      final compiled =
          await GameProjectCompiler(
            registry: authoring.registry,
            assets: PipelineAssetLibrary(
              readBundle: (version, _) async =>
                  version == source.version ? source : null,
            ),
          ).compile(
            documents: [StudioDocument.decode(document.encode())],
            startupLevel: 'main',
            profile: GameBuildProfile(id: 'native'),
          );
      expect(
        compiled.status,
        GameBuildStatus.ready,
        reason: '${compiled.diagnostics}',
      );
      final offline = PipelineBundle.decode(compiled.artifact!.bundle.encode());
      final recipe = CompiledGameProject.decode(
        utf8.decode(offline.resource('game.recipe').bytes),
        authoring.registry,
      );
      expect(
        recipe.sceneNodes['main']!.single['assetReference'],
        recipe.assets.single.toJson(),
      );
      var closed = 0;
      final scene = await GameRuntimeScene.load(
        recipe,
        loadAsset: (ref, token) async {
          final scope = offline.open();
          try {
            final model = await scope
                .load(offline.gltfRequest(sourceId: ref.id))
                .result;
            token.throwIfCancelled();
            return GameSceneAsset(
              root: model.instantiate(nativeDeformation: false),
              close: () async {
                await scope.close();
                closed++;
              },
            );
          } catch (_) {
            await scope.close();
            rethrow;
          }
        },
      );
      expect(scene.objects['model']!.children, isNotEmpty);
      final descendants = <Object3D>[scene.objects['model']!];
      var meshes = 0;
      while (descendants.isNotEmpty) {
        final child = descendants.removeLast();
        descendants.addAll(child.children);
        if (child is Mesh) meshes++;
      }
      expect(meshes, greaterThan(0));
      await scene.close();
      expect(closed, 1);
    },
  );
}
