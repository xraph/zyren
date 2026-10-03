part of '../../ai.dart';

final class GameAiStudioContribution {
  final GameAiWorkspace workspace;
  final Map<String, TrainingRunRequest> trainingProfiles;
  GameAiStudioContribution({
    required this.workspace,
    this.trainingProfiles = const {},
  });
  StudioEditorContribution get contribution => StudioEditorContribution(
    id: 'zyren.ai-editor',
    version: 1,
    attach: (context) {
      context.scope.keep(
        context.services.agents.register(
          TrainingAgentProvider(
            runner: workspace.runner,
            requests: trainingProfiles,
            currentRevision: () => context.scene.revision,
            permits: (_) => context.isAvailable && workspace.permitted,
            instanceId: context.scene.document.id,
          ),
        ),
      );
      for (final panel in [
        StudioEditorPanel(
          id: 'ai.brain',
          title: 'Brain',
          icon: Icons.psychology_outlined,
          defaultDock: StudioEditorDock.bottom,
          builder: (_, _) => KeyedSubtree(
            key: workspace.tours.perception,
            child: GameBrainInspector(workspace: workspace),
          ),
        ),
        StudioEditorPanel(
          id: 'ai.sensors',
          title: 'Sensors',
          icon: Icons.visibility_outlined,
          defaultDock: StudioEditorDock.bottom,
          builder: (_, _) => GameSensorInspector(workspace: workspace),
        ),
        StudioEditorPanel(
          id: 'ai.training',
          title: 'Training',
          icon: Icons.model_training,
          defaultDock: StudioEditorDock.bottom,
          builder: (_, _) => KeyedSubtree(
            key: workspace.tours.training,
            child: GameTrainingPanel(workspace: workspace),
          ),
        ),
      ]) {
        context.registerPanel(panel);
      }
    },
  );
}
