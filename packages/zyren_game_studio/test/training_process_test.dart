import 'dart:io';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_game_studio/training.dart';
import 'training_support.dart';

void main() {
  test(
    'missing worker is unavailable and a run cannot escape project scope',
    () async {
      final root = await Directory.systemTemp.createTemp('training-studio-');
      addTearDown(() => root.delete(recursive: true));
      final config = File('${root.path}/config.json');
      await config.writeAsString('{}');
      final request = TrainingRunRequest(
        executable: '/usr/bin/python3',
        executableArguments: const ['-m', 'zyren_train.cli'],
        projectDirectory: root.path,
        configPath: config.path,
        configFileHash: sha256.convert(await config.readAsBytes()).toString(),
        configHash: 'a' * 64,
        workerPath: '${root.path}/missing',
        runPath: '${root.path}/runs/one',
      );
      final runner = TrainingRunner();
      addTearDown(runner.close);
      final run = await runner.start(request);
      await run.done;
      expect(run.state, TrainingRunState.unavailable);
      await expectLater(
        runner.start(request.copyWith(runPath: '/tmp/escaped')),
        throwsArgumentError,
      );
    },
  );
  test(
    'actual process exit and receipt pins distinguish completion, crash and lost stream',
    () async {
      final root = await Directory.systemTemp.createTemp('training-process-');
      addTearDown(() => root.delete(recursive: true));
      final runner = TrainingRunner();
      addTearDown(runner.close);
      for (final mode in ['complete', 'crash', 'lost', 'corrupt']) {
        final run = await runner.start(await processFixture(root, mode));
        await run.done;
        expect(
          run.state,
          mode == 'complete'
              ? TrainingRunState.completed
              : TrainingRunState.failed,
          reason: run.error,
        );
        if (mode == 'complete') {
          expect(run.steps, 16);
          expect(run.checkpointHash, isNotNull);
        }
      }
    },
  );
  test(
    'SIGTERM stops actual child at receipt boundary and rejects damaged resume',
    () async {
      final root = await Directory.systemTemp.createTemp('training-stop-');
      addTearDown(() => root.delete(recursive: true));
      final runner = TrainingRunner();
      addTearDown(runner.close);
      final request = await processFixture(root, 'wait');
      final run = await runner.start(request);
      await run.changes.firstWhere(
        (_) => run.state == TrainingRunState.running,
      );
      await run.stop();
      expect(run.state, TrainingRunState.cancelled);
      expect(run.checkpointHash, isNotNull);
      await File(
        '${run.request.runPath}/${run.checkpointFile}',
      ).writeAsString('damaged');
      final resumed = await runner.start(request.copyWith(resume: true));
      await resumed.done;
      expect(resumed.state, TrainingRunState.failed);
      expect(resumed.error, contains('Checkpoint hash'));
    },
  );
  test(
    'receipt chain uses exact Python canonical bytes and rejects mutation',
    () {
      final data = <String, Object?>{
        'config_hash': 'a' * 64,
        'metrics': {'loss': 1e-7},
        'previous': '0' * 64,
        'sequence': 1,
        'state': 'running',
        'steps': 16,
      };
      // Python scientific notation deliberately differs from Dart's encoding.
      final canonical = jsonEncode(data).replaceAll('1e-7', '1e-07');
      final digest = sha256.convert(utf8.encode(canonical)).toString();
      final line = canonical.replaceFirst(
        '"state":',
        '"sha256":"$digest","state":',
      );
      final receipts = TrainingReceiptChain('a' * 64);
      expect(receipts.accept(line).steps, 16);
      expect(
        () =>
            TrainingReceiptChain('a' * 64).accept(line.replaceAll('16', '17')),
        throwsFormatException,
      );
      expect(() => receipts.accept(line), throwsFormatException);
    },
  );
}
