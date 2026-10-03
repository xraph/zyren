part of '../../ai.dart';

Future<void> showTrainingConfiguration(
  BuildContext context,
  GameAiWorkspace workspace,
) async {
  final project = TextEditingController(text: Directory.current.path);
  final executable = TextEditingController();
  final worker = TextEditingController();
  final template = TextEditingController();
  final output = TextEditingController(text: 'training/config.json');
  final run = TextEditingController(
    text: 'training/runs/run-${DateTime.now().millisecondsSinceEpoch}',
  );
  var busy = false;
  String? error;
  try {
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (_, update) => AlertDialog(
          title: const Text('Configure local training'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final field in [
                    (project, 'Project directory'),
                    (executable, 'Training executable'),
                    (worker, 'Frozen worker executable'),
                    (template, 'Scenario configuration template'),
                    (output, 'New pinned configuration path'),
                    (run, 'New run directory'),
                  ])
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: TextField(
                        controller: field.$1,
                        enabled: !busy,
                        decoration: InputDecoration(
                          labelText: field.$2,
                          isDense: true,
                        ),
                      ),
                    ),
                  const Text(
                    'Paths for the template, configuration and run must belong to this project. Existing configurations are not overwritten.',
                  ),
                  if (error != null) Text(error!),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(dialog),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      update(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        String scoped(String text) => File(text).isAbsolute
                            ? text
                            : '${project.text}/$text';
                        final toolchain = TrainingToolchain(
                          executable: executable.text,
                          worker: worker.text,
                          project: project.text,
                        );
                        final request = await toolchain.configure(
                          template: scoped(template.text),
                          output: scoped(output.text),
                          run: scoped(run.text),
                        );
                        workspace.trainingRequest = request;
                        workspace.refresh();
                        if (dialog.mounted) Navigator.pop(dialog);
                      } catch (e) {
                        if (dialog.mounted) {
                          update(() {
                            error = '$e';
                            busy = false;
                          });
                        }
                      }
                    },
              child: Text(busy ? 'Validating toolchain' : 'Configure'),
            ),
          ],
        ),
      ),
    );
  } finally {
    for (final controller in [
      project,
      executable,
      worker,
      template,
      output,
      run,
    ]) {
      controller.dispose();
    }
  }
}

Future<void> showModelImport(
  BuildContext context,
  GameAiWorkspace workspace,
) async {
  final path = TextEditingController();
  final cancellation = MlCancellationToken();
  String? error;
  var busy = false;
  try {
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (_, update) => AlertDialog(
          title: const Text('Validate model manifest'),
          content: SizedBox(
            width: 440,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: path,
                  enabled: !busy,
                  decoration: const InputDecoration(
                    labelText: 'Local manifest path',
                    isDense: true,
                  ),
                ),
                const Text(
                  'The shared asset resolver verifies ONNX bytes. This imports a candidate without activating it. Evaluation is required before activation.',
                ),
                if (error != null) Text(error!),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () { cancellation.cancel(); Navigator.pop(dialog); },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy
                  ? null
                  : () async {
                      update(() {
                        busy = true;
                        error = null;
                      });
                      try {
                        final file = File(path.text);
                        if (await file.length() > 1048576) {
                          throw FormatException(
                            'Manifest byte budget exceeded.',
                          );
                        }
                        final manifest = MlModelManifest.decode(
                          await file.readAsString(),
                        );
                        final original = workspace.group
                            ?.brainFor(workspace.selectedActor!)
                            ?.contract;
                        if (original == null) {
                          throw StateError(
                            'Select an active policy actor before import.',
                          );
                        }
                        final contract = PolicyContract(
                          model: manifest,
                          observation: original.observation,
                          decoder: original.decoder,
                          encoder: original.encoder,
                          observationInput: original.observationInput,
                          continuousOutput: original.continuousOutput,
                          discreteOutput: original.discreteOutput,
                          latencyTicks: original.latencyTicks,
                          cadenceTicks: original.cadenceTicks,
                          maxHiddenBytes: original.maxHiddenBytes,
                          maxHoldTicks: original.maxHoldTicks,
                        );
                        await workspace.importModel(contract, cancellation: cancellation);
                        if (dialog.mounted) Navigator.pop(dialog);
                      } catch (e) {
                        if (dialog.mounted) {
                          update(() {
                            error = '$e';
                            busy = false;
                          });
                        }
                      }
                    },
              child: Text(busy ? 'Validating manifest' : 'Import candidate'),
            ),
          ],
        ),
      ),
    );
  } finally {
    cancellation.cancel();
    path.dispose();
  }
}
