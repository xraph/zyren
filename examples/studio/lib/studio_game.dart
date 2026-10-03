import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:flutter_zyren_studio/flutter_zyren_studio.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/animation.dart';
import 'package:zyren_game_studio/play.dart';
import 'package:zyren_game_studio/export.dart';
import 'package:zyren_game_studio/export_io.dart';
import 'package:zyren_game_studio/export_ui.dart';
import 'package:zyren_game_studio/gameplay.dart';
import 'package:zyren_game_studio/zyren_game_studio.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'studio_assets.dart';

List<StudioEditorContribution> studioGameContributions({
  required SceneRuntime runtime,
  StudioPipelineAssets? assets,
  Future<void> Function()? importAssets,
  GameCollaborationAdapter? collaboration,
  Future<void> Function()? leaveSession,
  GameBuildPublisher? publishGame,
}) {
  final rules = GameRuleLibrary();
  final authoring = createGameDevelopmentAuthoring(rules: rules);
  final levels = GameLevelAuthoring(authoring);
  final compiler = GameProjectCompiler(
    registry: authoring.registry,
    assets:
        assets?.library ??
        PipelineAssetLibrary(readBundle: (_, _) async => null),
  );
  String? outputLocation;
  List<String> validation(StudioDocument document) => [
    ...levels.validateLinks([document]),
    if (levels.navigation(document) case final navigation?)
      if (!navigation.isCurrent(document))
        'Navigation is stale. Bake it again before play or export.',
  ];
  return [
    GameStudioContribution(authoring).contribution,
    GameLevelStudioContribution(authoring, rules).contribution,
    GameBuildContribution(
      collaboration: collaboration,
      leaveSession: leaveSession,
      importAssets: importAssets,
      createCommands: (context) => GameBuildCommands(
        compiler: compiler,
        documents: () => [context.scene.capture()],
        revision: () => context.scene.revision,
        startupLevel: () => authoring.expanded(context.scene.capture()).levelId,
        profile: () => levels.profile(context.scene.capture()),
        allows: (scope) => context.capabilities.contains(scope),
        isAvailable: () => context.isAvailable,
        hostValidation: () => validation(context.scene.capture()),
        outputLocation: () => outputLocation,
        publish:
            publishGame ??
            (bundle, token, check) async {
              outputLocation = await _publishGame(bundle, token, check);
            },
        outputLabel: 'Choose a .zygame file when the export is ready.',
      ),
    ).contribution,
    GamePlayContribution(
      authoring: authoring,
      runtime: runtime,
      animationFactory: createGameCharacterAnimation,
      systemFactory: (play) => [
        GamePlayGameplay(play, rules),
        GamePlayEventJournal(),
      ],
      importAssets: importAssets == null ? null : (_) => importAssets(),
      audioFactory: (scene) {
        scene.scene.add(scene.camera);
        return SpatialAudio(
          root: scene.scene,
          listener: AudioListener(scene.camera),
        );
      },
      compile: (document, cancellation) async {
        final problems = validation(document);
        if (problems.isNotEmpty) throw StateError(problems.join('\n'));
        final result = await compiler.compile(
          documents: [document],
          startupLevel: authoring.expanded(document).levelId,
          profile: levels.profile(document),
          cancellation: cancellation,
        );
        if (result.status != GameBuildStatus.ready) {
          throw StateError(result.diagnostics.join('\n'));
        }
        return result.artifact!.project;
      },
    ).contribution,
  ];
}

Future<String> _publishGame(
  PipelineBundle bundle,
  LoadCancellation cancellation,
  void Function() checkBeforeCommit,
) async {
  checkBeforeCommit();
  final location = await getSaveLocation(
    suggestedName: 'game.zygame',
    acceptedTypeGroups: [
      const XTypeGroup(label: 'Zyren game', extensions: ['zygame']),
    ],
  );
  cancellation.throwIfCancelled();
  checkBeforeCommit();
  if (location == null) throw LoadCancelled();
  await GameFilePublisher(
    File(location.path),
  ).publish(bundle, cancellation, checkBeforeCommit);
  return location.path;
}
