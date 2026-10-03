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
  Future<String> readPinnedConfiguration(TrainingRunRequest request) async {
    final root = await Directory(project).resolveSymbolicLinks();
    await _scopedPath(root, request.configPath);
    final file = File(request.configPath);
    if (await file.length() > 1048576) {
      throw FormatException('Configuration byte limit exceeded.');
    }
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != request.configFileHash) {
      throw FormatException('Pinned configuration changed.');
    }
    return utf8.decode(bytes);
  }

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
    final result = await artifactCommand([
      'configure',
      '--template',
      template,
      '--worker',
      worker,
      '--output',
      output,
    ], timeout: const Duration(seconds: 30));
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

/// Auxiliary T2/T4/T5 commands use the same executable and project boundary.
extension TrainingArtifactCommands on TrainingToolchain {
  Future<Map<String, dynamic>> artifactCommand(
    List<String> command, {
    Duration timeout = const Duration(minutes: 2),
  }) async {
    if (command.isEmpty ||
        command.length > 32 ||
        command.any((v) => v.length > 4096 || v.contains('\u0000'))) {
      throw ArgumentError('Invalid artifact command.');
    }
    final process = await Process.start(
      executable,
      [...arguments, ...command],
      workingDirectory: project,
      runInShell: false,
    );
    final output = <int>[], error = <int>[];
    var exceeded = false;
    void collect(List<int> target, List<int> value) {
      if (target.length + value.length > 1048576) {
        exceeded = true;
        process.kill(ProcessSignal.sigterm);
        return;
      }
      target.addAll(value);
    }

    final stdout = process.stdout.listen((v) => collect(output, v));
    final stderr = process.stderr.listen((v) => collect(error, v));
    final finish = Future.wait([
      stdout.asFuture<void>(),
      stderr.asFuture<void>(),
    ]);
    final timer = Timer(timeout, () => process.kill(ProcessSignal.sigkill));
    try {
      final code = await process.exitCode;
      await finish.timeout(const Duration(seconds: 2));
      if (exceeded || code != 0) {
        throw StateError(
          'Artifact command failed: ${utf8.decode(error, allowMalformed: true)}',
        );
      }
      final value = jsonDecode(utf8.decode(output));
      if (value is! Map<String, dynamic>) {
        throw FormatException('Artifact command did not return an object.');
      }
      return value;
    } finally {
      timer.cancel();
      await stdout.cancel();
      await stderr.cancel();
    }
  }
}
