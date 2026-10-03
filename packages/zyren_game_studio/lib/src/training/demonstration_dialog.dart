part of '../../ai.dart';

Future<void> showDemonstrationRecorder(
  BuildContext context,
  GameAiWorkspace workspace,
) async {
  final request = workspace.trainingRequest, toolchain = workspace.toolchain;
  if (request == null || toolchain == null) return;
  final config =
      jsonDecode(await toolchain.readPinnedConfiguration(request))
          as Map<String, dynamic>;
  final scenarios = (config['scenarios'] as List).cast<Map<String, dynamic>>();
  var selected = scenarios.first['id'] as String,
      source = 'scripted',
      busy = false;
  String? error;
  final trace = TextEditingController();
  final session = TextEditingController(
    text: 'studio-${DateTime.now().millisecondsSinceEpoch}',
  );
  final output = TextEditingController(
    text: '${request.projectDirectory}/recordings/${session.text}',
  );
  try {
    if (!context.mounted) return;
    await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (_, update) => AlertDialog(
          title: const Text('Record and replay a demonstration'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selected,
                    decoration: const InputDecoration(
                      labelText: 'Pinned scenario',
                      isDense: true,
                    ),
                    items: [
                      for (final scenario in scenarios)
                        DropdownMenuItem(
                          value: scenario['id'] as String,
                          child: Text(
                            '${scenario['id']} · ${scenario['partition']}',
                          ),
                        ),
                    ],
                    onChanged: busy ? null : (v) => update(() => selected = v!),
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: source,
                    decoration: const InputDecoration(
                      labelText: 'Action source',
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'scripted',
                        child: Text('Scripted baseline'),
                      ),
                      DropdownMenuItem(
                        value: 'player',
                        child: Text('Recorded controller action trace'),
                      ),
                    ],
                    onChanged: busy ? null : (v) => update(() => source = v!),
                  ),
                  if (source == 'player')
                    TextField(
                      controller: trace,
                      decoration: const InputDecoration(
                        labelText: 'Actual controller trace JSON path',
                        isDense: true,
                      ),
                    ),
                  TextField(
                    controller: session,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: 'Recording session ID',
                      isDense: true,
                    ),
                  ),
                  TextField(
                    controller: output,
                    enabled: !busy,
                    decoration: const InputDecoration(
                      labelText: 'New recording directory',
                      isDense: true,
                    ),
                  ),
                  const Text(
                    'The prepared native worker applies these actions through shared controllers. A trace is labeled as recorded input; physical device qualification remains unknown.',
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
                        if (!workspace.permitted) {
                          throw StateError('Recording access was revoked.');
                        }
                        final scenario = scenarios.singleWhere(
                          (v) => v['id'] == selected,
                        );
                        final spec = File(
                          '${request.projectDirectory}/recording-spec-${session.text}.json',
                        );
                        if (!RegExp(
                          r'^[a-zA-Z0-9_.-]{1,128}$',
                        ).hasMatch(session.text)) {
                          throw FormatException('Invalid recording ID.');
                        }
                        final root = await Directory(
                          request.projectDirectory,
                        ).resolveSymbolicLinks();
                        await _studioScopedPath(root, spec.path);
                        if (await spec.exists()) {
                          throw StateError(
                            'Recording identity already exists.',
                          );
                        }
                        await spec.writeAsString(
                          jsonEncode(scenario),
                          flush: true,
                        );
                        final recorder = DemonstrationRecorder(toolchain);
                        final artifact = await recorder.record(
                          scenarioPath: spec.path,
                          output: output.text,
                          sessionId: session.text,
                          source: source,
                          actionTrace: source == 'player' ? trace.text : null,
                        );
                        await recorder.replay(output.text, artifact);
                        if (workspace.demonstrations.length >= 64) {
                          throw StateError(
                            'Demonstration view capacity reached.',
                          );
                        }
                        workspace.demonstrations.add(artifact);
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
              child: Text(
                busy ? 'Recording and verifying replay' : 'Record and verify',
              ),
            ),
          ],
        ),
      ),
    );
  } finally {
    trace.dispose();
    session.dispose();
    output.dispose();
  }
}

Future<void> _studioScopedPath(String project, String path) async {
  // The pure artifact command validates actual paths again before process launch.
  final file = File(path);
  final parent = await file.parent.resolveSymbolicLinks();
  if (parent != project && !parent.startsWith('$project/')) {
    throw ArgumentError('Recording path escapes project scope.');
  }
}
