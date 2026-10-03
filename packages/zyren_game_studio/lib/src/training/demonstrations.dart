part of '../../training.dart';

final class DemonstrationArtifact {
  final String manifestHash, observationHash, actionHash, source, partition;
  final int steps;
  DemonstrationArtifact({
    required this.manifestHash,
    required this.observationHash,
    required this.actionHash,
    required this.source,
    required this.partition,
    required this.steps,
  }) {
    if (![manifestHash, observationHash, actionHash].every(_digest) ||
        !['player', 'scripted'].contains(source) ||
        !['train', 'validation', 'test'].contains(partition) ||
        steps < 1 ||
        steps > 10000000) {
      throw ArgumentError('Invalid demonstration pins.');
    }
  }
}

final class DemonstrationRecorder {
  final TrainingToolchain toolchain;
  DemonstrationRecorder(this.toolchain);
  Future<DemonstrationArtifact> record({
    required String scenarioPath,
    required String output,
    required String sessionId,
    String source = 'scripted',
    String? actionTrace,
  }) async {
    final root = await Directory(toolchain.project).resolveSymbolicLinks();
    await _scopedPath(root, scenarioPath);
    await _scopedPath(root, output);
    if (!['player', 'scripted'].contains(source) ||
        !RegExp(r'^[a-zA-Z0-9_.-]{1,128}$').hasMatch(sessionId) ||
        source == 'player' && actionTrace == null) {
      throw ArgumentError(
        'Player recording requires an actual controller trace.',
      );
    }
    if (actionTrace != null) await _scopedPath(root, actionTrace);
    final result = await toolchain.artifactCommand([
      'record',
      '--worker',
      toolchain.worker,
      '--cwd',
      toolchain.project,
      '--scenario-spec',
      scenarioPath,
      '--output',
      output,
      '--source',
      source,
      '--session-id',
      sessionId,
      if (actionTrace != null) ...['--actions', actionTrace],
    ]);
    if (result['state'] != 'completed') {
      throw StateError('Demonstration did not finalize.');
    }
    return read(output, expectedHash: result['manifest_hash'] as String);
  }

  Future<DemonstrationArtifact> read(
    String directory, {
    required String expectedHash,
  }) async {
    final root = await Directory(toolchain.project).resolveSymbolicLinks();
    await _scopedPath(root, directory);
    final file = File('$directory/manifest.json');
    if (!await file.exists() || await file.length() > 16777216) {
      throw FormatException('Demonstration manifest is missing or oversized.');
    }
    final bytes = await file.readAsBytes();
    if (sha256.convert(bytes).toString() != expectedHash) {
      throw FormatException('Demonstration manifest pin differs.');
    }
    final data = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    final chunks = data['chunks'] as List, episodes = data['episodes'] as List;
    if (data['schema_version'] != 1 ||
        chunks.isEmpty ||
        chunks.length > 256 ||
        episodes.isEmpty ||
        episodes.length > 256) {
      throw FormatException('Demonstration structure differs.');
    }
    var records = 0, payload = 0;
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i] as Map<String, dynamic>;
      if (chunk['file'] != 'chunk-${i.toString().padLeft(6, '0')}.jsonl' ||
          chunk['records'] is! int ||
          chunk['records'] < 1 ||
          chunk['records'] > 1024) {
        throw FormatException('Demonstration chunk identity differs.');
      }
      final path = '$directory/${chunk['file']}';
      await _scopedPath(root, path);
      final source = File(path);
      if (!await source.exists() ||
          await source.length() > 8388608 ||
          sha256.convert(await source.readAsBytes()).toString() !=
              chunk['sha256']) {
        throw FormatException('Demonstration chunk hash differs.');
      }
      final size = await source.length();
      payload += size;
      if (size != chunk['bytes'] || payload > 67108864) {
        throw FormatException('Demonstration payload budget exceeded.');
      }
      records += chunk['records'] as int;
    }
    final steps = episodes.fold<int>(0, (n, e) => n + (e['steps'] as int));
    if (records != steps ||
        episodes.any(
          (e) =>
              e['partition'] != data['partition'] ||
              e['session_id'] != data['session_id'] ||
              e['observation_schema_hash'] != data['observation_schema_hash'] ||
              e['action_schema_hash'] != data['action_schema_hash'],
        )) {
      throw FormatException('Demonstration episode pins differ.');
    }
    return DemonstrationArtifact(
      manifestHash: expectedHash,
      observationHash: data['observation_schema_hash'] as String,
      actionHash: data['action_schema_hash'] as String,
      source: data['recording']['source'] as String,
      partition: data['partition'] as String,
      steps: steps,
    );
  }

  Future<Map<String, dynamic>> replay(
    String directory,
    DemonstrationArtifact artifact,
  ) async {
    await read(directory, expectedHash: artifact.manifestHash);
    final result = await toolchain.artifactCommand([
      'replay',
      '--worker',
      toolchain.worker,
      '--cwd',
      toolchain.project,
      '--recording',
      directory,
    ]);
    if (result['matched'] != true ||
        result['observation_schema_hash'] != artifact.observationHash ||
        result['action_schema_hash'] != artifact.actionHash) {
      throw FormatException('Replay did not match recording pins.');
    }
    return result;
  }
}
