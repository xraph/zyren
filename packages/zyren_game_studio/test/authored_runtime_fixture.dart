import 'package:flutter_test/flutter_test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/play.dart';
import 'package:zyren_game_studio/gameplay.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'play_session_test.dart' show TestRenderer;

Future<
  ({GamePlaySession play, GamePlayGameplay gameplay, StudioScene authored})
>
start({
  double radius = .25,
  String spawn = 'spawn',
  bool alternateSpawn = false,
}) async {
  final authoring = createGameDevelopmentAuthoring();
  var original = GameTemplate(
    GameTemplateKind.exploration,
    authoring,
  ).create(projectId: 'checkpoint-contract').document;
  if (alternateSpawn) {
    original = original.copyWith(
      nodes: [
        ...original.nodes,
        StudioNode(
          id: 'alternate-spawn',
          label: 'Alternate spawn',
          kind: StudioNodeKind.group,
          position: const Vec3(6, 1.5, -3),
        ),
      ],
    );
    original = GameLevelAuthoring(
      authoring,
    ).spawn(original, 'alternate-spawn', 'alternate');
  }
  final document = authoring.setFields(
    original,
    nodeId: 'checkpoint',
    component: 'game.checkpoint',
    fields: {'radius': radius, 'spawn': spawn},
  );
  final build =
      await GameProjectCompiler(
        registry: authoring.registry,
        assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
      ).compile(
        documents: [StudioDocument.decode(document.encode())],
        startupLevel: 'main',
        profile: GameBuildProfile(id: 'checkpoint-contract'),
      );
  expect(build.status, GameBuildStatus.ready, reason: '${build.diagnostics}');
  final authored = StudioScene(document);
  late GamePlayGameplay gameplay;
  final play = GamePlaySession(
    authoredScene: authored,
    fixtureRendererFactory: () async => TestRenderer(),
    systemFactory: (play) => [
      gameplay = GamePlayGameplay(play, GameRuleLibrary()),
    ],
  );
  try {
    await play.start(build.artifact!.project);
    play.simulation!.step();
    return (play: play, gameplay: gameplay, authored: authored);
  } catch (_) {
    await play.stop();
    play.dispose();
    rethrow;
  }
}

void advance(GamePlaySession play, [int count = 12]) {
  for (var i = 0; i < count; i++) {
    play.simulation!.step();
  }
}
