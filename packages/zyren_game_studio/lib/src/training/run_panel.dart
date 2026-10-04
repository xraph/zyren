part of '../../ai.dart';

class GameTrainingPanel extends StatelessWidget {
  final GameAiWorkspace workspace;
  const GameTrainingPanel({super.key, required this.workspace});
  Future<void> _action(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      workspace.error = '$e';
      workspace.refresh();
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace,
    builder: (_, _) {
      if (!workspace.canInspectTraining) {
        return const ZeroState(
          title: 'Training access denied',
          message:
              'You need project training access to inspect or start a local run.',
        );
      }
      final run = workspace.runner.runs.lastOrNull;
      final candidate = workspace.candidate;
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: workspace.canTrain
                      ? () => showTrainingConfiguration(context, workspace)
                      : null,
                  child: const Text('Configure local worker'),
                ),
                if (workspace.trainingRequest != null)
                  TextButton(
                    onPressed: () => _action(
                      context,
                      () => showScenarioEditor(context, workspace),
                    ),
                    child: const Text('Edit scenarios and rewards'),
                  ),
                FilledButton(
                  onPressed:
                      !workspace.canTrain ||
                          workspace.trainingRequest == null ||
                          run != null &&
                              ![
                                TrainingRunState.completed,
                                TrainingRunState.cancelled,
                                TrainingRunState.failed,
                                TrainingRunState.unavailable,
                              ].contains(run.state)
                      ? null
                      : () => _action(context, workspace.start),
                  child: const Text('Start local run'),
                ),
                if (run != null &&
                    [
                      TrainingRunState.queued,
                      TrainingRunState.running,
                      TrainingRunState.stopping,
                    ].contains(run.state))
                  TextButton(
                    onPressed:
                        !workspace.canStopTraining ||
                            run.state == TrainingRunState.stopping
                        ? null
                        : () => _action(context, workspace.stopTraining),
                    child: const Text('Stop at update boundary'),
                  ),
                if (run != null &&
                    [
                      TrainingRunState.cancelled,
                      TrainingRunState.failed,
                    ].contains(run.state))
                  TextButton(
                    onPressed: () =>
                        _action(context, () => workspace.start(resume: true)),
                    child: const Text('Resume verified checkpoint'),
                  ),
                _tourButton(context, 'studio.ai.train', 'Training tour'),
              ],
            ),
            if (workspace.scenarioTemplatePath != null)
              const Text(
                'Edited template saved. Configure a new pinned run to use it.',
              ),
            if (workspace.trainingRequest == null)
              const ZeroState(
                title: 'Local worker unavailable',
                message:
                    'Configure the training executable, frozen worker, pinned configuration and project run directory. Cloud execution is disabled.',
              ),
            if (workspace.error != null || run?.error != null)
              ZeroState(
                title: 'Training request failed',
                message: workspace.error ?? run!.error!,
              ),
            if (run != null) ...[
              Text(
                '${run.state.name} · ${run.steps} steps · ${run.updates} updates · exit ${run.exitCode ?? 'pending'}',
              ),
              const Text(
                'Training completion does not establish policy quality.',
              ),
              if (run.checkpointHash != null)
                SelectableText(
                  'Checkpoint ${run.checkpointFile}\n${run.checkpointHash}',
                ),
              ExpansionTile(
                title: Text('Verified receipts (${run.receipts.length})'),
                children: [
                  for (final receipt in run.receipts.reversed.take(8))
                    SelectableText(
                      '${receipt.sequence}: ${jsonEncode(receipt.data)}',
                    ),
                ],
              ),
              ExpansionTile(
                title: const Text('Bounded process logs'),
                children: [
                  for (final log in run.logs.take(128)) SelectableText(log),
                ],
              ),
            ],
            const Divider(),
            GameModelCatalog(workspace: workspace),
            Wrap(
              spacing: 8,
              children: [
                const Text('Model library'),
                TextButton(
                  onPressed:
                      workspace.importer == null &&
                          workspace.prepareArtifact == null
                      ? null
                      : () => showModelImport(context, workspace),
                  child: const Text('Import local model'),
                ),
              ],
            ),
            if (candidate != null && workspace.importer != null)
              TextButton(
                onPressed: () => _action(
                  context,
                  () => showEvaluationImport(context, workspace),
                ),
                child: const Text('Verify evaluation receipt'),
              ),
            if (candidate == null)
              const ZeroState(
                title: 'No model imported',
                message:
                    'Validate a registered ONNX manifest against the selected NPC schema. Import does not activate it.',
              ),
            if (candidate != null) ...[
              SelectableText(
                '${candidate.contract.model.id}\n${candidate.contract.model.sha256}',
              ),
              Text(
                'Compatible: ${candidate.compatible} · evaluated: ${candidate.accepted}',
              ),
              for (final issue in candidate.issues) Text(issue),
              ExpansionTile(
                title: const Text('Observation schema'),
                children: [
                  for (final field in candidate.contract.observation.fields)
                    Text(
                      '${field.name} · ${field.units} · width ${field.width} · [${field.min}, ${field.max}]',
                    ),
                ],
              ),
              FilledButton(
                onPressed: !candidate.accepted || workspace.activation == null
                    ? null
                    : () => _action(context, workspace.activate),
                child: const Text('Activate evaluated model'),
              ),
              if (candidate.evaluation != null) ...[
                SelectableText(
                  'Evaluation ${candidate.evaluation!.fixedHz == null ? 'rate unavailable' : '${candidate.evaluation!.fixedHz} Hz'} · ${candidate.evaluation!.receiptHash}',
                ),
                for (final row in candidate.evaluation!.cases.take(32))
                  Text(
                    '${row['id']} · ${row['family']} · ${(row['seeds'] as List?)?.length ?? 0} layout seeds',
                  ),
              ],
            ],
            if (workspace.activeModelHash != null)
              SelectableText('Active model ${workspace.activeModelHash}'),
            if (workspace.toolchain != null)
              TextButton(
                onPressed: () => _action(
                  context,
                  () => showDemonstrationRecorder(context, workspace),
                ),
                child: const Text('Record demonstration'),
              ),
            for (final demo in workspace.demonstrations.take(64))
              Text(
                '${demo.source} · ${demo.partition} · ${demo.steps} steps · ${demo.manifestHash}',
              ),
          ],
        ),
      );
    },
  );
}
