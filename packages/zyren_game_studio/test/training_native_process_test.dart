import 'dart:io';
import 'dart:convert';
import 'package:test/test.dart';
import 'package:zyren_game_studio/training.dart';

void main() {
  test(
    'Studio records actual native scripted demonstration and verifies replay/chunk hashes',
    () async {
      final root = Directory.current.path.endsWith('zyren_game_studio')
          ? Directory.current.parent.parent.path
          : Directory.current.path;
      final project = await Directory(
        '$root/.superpowers/sdd/README',
      ).createTemp('s6-recording-');
      addTearDown(() => project.delete(recursive: true));
      final config =
          jsonDecode(
                await File(
                  '$root/.superpowers/sdd/README/task-T3-cpu-v3-config.json',
                ).readAsString(),
              )
              as Map<String, dynamic>;
      final spec = File('${project.path}/scenario.json');
      await spec.writeAsString(jsonEncode((config['scenarios'] as List).first));
      final recorder = DemonstrationRecorder(
        TrainingToolchain(
          executable: '$root/tool/zyren_train/.venv/bin/zyren-train',
          worker:
              '$root/examples/game_lab/training_worker/.dart_tool/native_worker/bundle/bin/train_worker',
          project: project.path,
        ),
      );
      final directory = '${project.path}/recording';
      final artifact = await recorder.record(
        scenarioPath: spec.path,
        output: directory,
        sessionId: 'studio-probe',
      );
      expect(artifact.source, 'scripted');
      expect(artifact.steps, greaterThan(0));
      final replay = await recorder.replay(directory, artifact);
      expect(replay['matched'], true);
      await File('$directory/chunk-000000.jsonl').writeAsString('corrupted');
      await expectLater(
        recorder.read(directory, expectedHash: artifact.manifestHash),
        throwsFormatException,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
  test(
    'Studio runner configures actual T3 CPU trainer, cancels and resumes pinned checkpoint',
    () async {
      final repository = Directory.current.path.endsWith('zyren_game_studio')
          ? Directory.current.parent.parent.path
          : Directory.current.path;
      final source = File(
        '$repository/.superpowers/sdd/README/task-T3-cpu-v3-config.json',
      );
      final worker = File(
        '$repository/examples/game_lab/training_worker/.dart_tool/native_worker/bundle/bin/train_worker',
      );
      final executable = File(
        '$repository/tool/zyren_train/.venv/bin/zyren-train',
      );
      expect(
        await worker.exists(),
        isTrue,
        reason: 'Prepare the native T1 worker first.',
      );
      expect(
        await executable.exists(),
        isTrue,
        reason: 'Resolve the locked Python training project first.',
      );
      final project = await Directory(
        '$repository/.superpowers/sdd/README',
      ).createTemp('s6-training-');
      addTearDown(() => project.delete(recursive: true));
      final template = File('${project.path}/template.json');
      await source.copy(template.path);
      final configured =
          await TrainingToolchain(
            executable: executable.path,
            worker: worker.path,
            project: project.path,
          ).configure(
            template: template.path,
            output: '${project.path}/config.json',
            run: '${project.path}/run',
          );
      final request = TrainingRunRequest(
        executable: configured.executable,
        projectDirectory: configured.projectDirectory,
        configPath: configured.configPath,
        configFileHash: configured.configFileHash,
        configHash: configured.configHash,
        workerPath: configured.workerPath,
        runPath: configured.runPath,
        stopAfterUpdates: 1,
      );
      final runner = TrainingRunner();
      addTearDown(runner.close);
      final cancelled = await runner.start(request);
      await cancelled.done;
      expect(
        cancelled.state,
        TrainingRunState.cancelled,
        reason: cancelled.error,
      );
      expect(cancelled.steps, 16);
      expect(cancelled.exitCode, 0);
      expect(cancelled.checkpointHash, isNotNull);
      final resume = configured.copyWith(resume: true);
      final completed = await runner.start(resume);
      await completed.done;
      expect(
        completed.state,
        TrainingRunState.completed,
        reason: completed.error,
      );
      expect(completed.steps, 32);
      expect(completed.exitCode, 0);
      expect(completed.receipts.last.data['workers_closed'], true);
      expect(completed.receipts.last.data['worker_exit_codes'], [0]);
      expect(
        completed.checkpointHash,
        completed.receipts.last.data['checkpoint_sha256'],
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
