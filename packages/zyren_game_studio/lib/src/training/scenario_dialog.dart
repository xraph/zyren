part of '../../ai.dart';

Future<void> showScenarioEditor(
  BuildContext context,
  GameAiWorkspace workspace,
) async {
  final request = workspace.trainingRequest;
  if (request == null) return;
  final source = File(workspace.scenarioTemplatePath ?? request.configPath);
  if (await source.length() > 1048576) {
    throw FormatException('Scenario byte budget exceeded.');
  }
  final document = TrainingScenarioDocument(
    jsonDecode(await source.readAsString()) as Map<String, dynamic>,
  );
  final text = TextEditingController(
    text: const JsonEncoder.withIndent(
      '  ',
    ).convert(document.data['scenarios']),
  );
  final rewards = TextEditingController(
    text: jsonEncode(document.data['rewards']),
  );
  final output = TextEditingController(
    text:
        '${request.projectDirectory}/training/scenarios-${DateTime.now().millisecondsSinceEpoch}.json',
  );
  String? error;
  try {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (_, update) => AlertDialog(
          title: const Text('Scenarios and reward terms'),
          content: SizedBox(
            width: 640,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Preserve train/validation/test splits and schema hashes. The existing trainer validates the complete configuration before a run.',
                  ),
                  TextField(
                    controller: text,
                    minLines: 4,
                    maxLines: 12,
                    decoration: const InputDecoration(
                      labelText: 'Scenario records (JSON)',
                      isDense: true,
                    ),
                  ),
                  TextField(
                    controller: rewards,
                    minLines: 1,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Reward term weights (JSON)',
                      isDense: true,
                    ),
                  ),
                  TextField(
                    controller: output,
                    decoration: const InputDecoration(
                      labelText: 'Save a new template',
                      isDense: true,
                    ),
                  ),
                  if (error != null) Text(error!),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  if (!workspace.canTrain) {
                    throw StateError('Training authoring access was revoked.');
                  }
                  if (text.text.length > 1048576 ||
                      rewards.text.length > 16384) {
                    throw FormatException(
                      'Scenario or reward text exceeds its byte budget.',
                    );
                  }
                  final next = document.data;
                  next['scenarios'] = jsonDecode(text.text);
                  final edited = TrainingScenarioDocument(next);
                  final weights =
                      (jsonDecode(rewards.text) as Map<String, dynamic>).map(
                        (k, v) => MapEntry(k, (v as num).toDouble()),
                      );
                  if (await File(output.text).exists()) {
                    throw StateError('Choose a new template path.');
                  }
                  await TrainingRewards(
                    weights,
                  ).apply(edited).save(request.projectDirectory, output.text);
                  workspace.scenarioTemplatePath = output.text;
                  workspace.refresh();
                  if (dialog.mounted) Navigator.pop(dialog);
                } catch (e) {
                  if (dialog.mounted) update(() => error = '$e');
                }
              },
              child: const Text('Save template copy'),
            ),
          ],
        ),
      ),
    );
  } finally {
    text.dispose();
    rewards.dispose();
    output.dispose();
  }
}
