part of '../zyren_game_studio.dart';

final class GameStudioContribution {
  final GameAuthoring authoring;
  GameStudioContribution(this.authoring);
  StudioEditorContribution get contribution => StudioEditorContribution(
    id: 'zyren.game-editor',
    version: 1,
    attach: (context) {
      context.scope.keep(
        context.scene.extensionRegistry.register(authoring.codec),
      );
      context.scope.keep(
        context.services.agents.register(
          GameAuthoringAgent(
            authoring: authoring,
            scene: context.scene,
            isAvailable: () => context.isAvailable,
            applyDocument: context.applyDocument,
            instanceId: context.scene.document.id,
          ),
        ),
      );
      context.registerInspector(
        StudioEditorInspector(
          id: 'game.components',
          title: 'Game components',
          applies: (c) => c.selectedId != null,
          builder: (_, c) =>
              GameComponentInspector(context: c, authoring: authoring),
        ),
      );
      context.registerPanel(
        StudioEditorPanel(
          id: 'game.outline',
          title: 'Game entities',
          icon: Icons.sports_esports,
          defaultDock: StudioEditorDock.leftLower,
          builder: (_, c) => GameOutline(context: c, authoring: authoring),
        ),
      );
      context.registerPanel(
        StudioEditorPanel(
          id: 'game.problems',
          title: 'Game problems',
          icon: Icons.rule,
          defaultDock: StudioEditorDock.bottom,
          builder: (_, c) => GameProblems(context: c, authoring: authoring),
        ),
      );
      context.registerValidator(
        StudioEditorValidator(
          id: 'game.components',
          validate: (c, document) => [
            for (final issue in authoring.validate(document))
              StudioEditorProblem(
                '${issue.nodeId ?? document.id}/${issue.component ?? "game"}/${issue.field ?? "record"}',
                issue.message,
                blocking: issue.blocksPlay,
              ),
          ],
        ),
      );
      context.registerCommand(
        StudioEditorCommand(
          id: 'game.initialize',
          label: 'Enable game authoring',
          enabled: (c) =>
              c.isAvailable &&
              !c.scene.document.extensions.containsKey(
                authoring.codec.namespace,
              ),
          handler: (c) =>
              c.applyDocument(authoring.initialize(c.scene.document)),
        ),
      );
    },
  );
}
