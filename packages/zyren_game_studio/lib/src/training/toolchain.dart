part of '../../training.dart';

final class TrainingToolchain {
  final String executable, worker, project;
  final List<String> arguments;
  TrainingToolchain({
    required this.executable,
    required this.worker,
    required this.project,
    List<String> arguments = const [],
  }) : arguments = List.unmodifiable(arguments);
  Future<TrainingRunRequest> configure({
    required String template,
    required String output,
    required String run,
  }) async {
    final root = await Directory(project).resolveSymbolicLinks();
    await _scopedPath(root, template);
    await _scopedPath(root, output);
    await _scopedPath(root, run);
    if (!await File(worker).exists()) {
      throw StateError('Frozen training worker is unavailable.');
    }
    final process = await Process.start(
      executable,
      [
        ...arguments,
        'configure',
        '--template',
        template,
        '--worker',
        worker,
        '--output',
        output,
      ],
      workingDirectory: project,
      runInShell: false,
    );
    final bytes = <int>[], errors = <int>[];
    var exceeded = false;
    void collect(List<int> target, List<int> chunk) {
      if (target.length + chunk.length > 1048576) {
        exceeded = true;
        process.kill(ProcessSignal.sigterm);
        return;
      }
      target.addAll(chunk);
    }

    final out = process.stdout.listen((v) => collect(bytes, v));
    final err = process.stderr.listen((v) => collect(errors, v));
    final timeout = Timer(
      const Duration(seconds: 30),
      () => process.kill(ProcessSignal.sigkill),
    );
    final code = await process.exitCode;
    timeout.cancel();
    await out.cancel();
    await err.cancel();
    if (code != 0 || exceeded) {
      throw StateError(
        'Training configuration failed: ${utf8.decode(errors, allowMalformed: true)}',
      );
    }
    final result = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (!_digest(result['config_hash']) ||
        !await File(output).exists() ||
        await File(output).length() > 1048576) {
      throw FormatException('Configuration receipt is invalid.');
    }
    return TrainingRunRequest(
      executable: executable,
      executableArguments: arguments,
      workerPath: worker,
      projectDirectory: project,
      configPath: output,
      configHash: result['config_hash'] as String,
      configFileHash: sha256
          .convert(await File(output).readAsBytes())
          .toString(),
      runPath: run,
    );
  }
}
