import 'dart:async';
import 'dart:io';

// Runs the test suite of every workspace member that has a test/ directory,
// one suite at a time, and exits non-zero if any suite fails.
//
//   dart run tool/run_package_tests.dart [--shard 1/3] [--only name,name] [--list]
//
// `--only` takes member paths or their last segment, such as
// `packages/zyren_tools` or `planet`.
//
// Every suite runs with --concurrency=1. Several packages drive native worlds
// whose live-object counters are process-wide, and test files running in
// parallel isolates then count each other's bodies and worlds.

/// Suites whose fixtures are addressed from the workspace root.
const fromRoot = {
  'packages/zyren_collaboration',
  'packages/zyren_engineering',
  'packages/zyren_pipeline',
};

/// Suites CI does not run, with the reason. Keep each reason specific.
const skipped = <String, String>{};

const suiteTimeout = Duration(minutes: 25);

List<String> workspaceMembers() {
  final lines = File('pubspec.yaml').readAsLinesSync();
  final members = <String>[];
  var inWorkspace = false;
  for (final line in lines) {
    if (line.startsWith('workspace:')) {
      inWorkspace = true;
      continue;
    }
    if (inWorkspace) {
      final match = RegExp(r'^\s+-\s+(\S+)\s*$').firstMatch(line);
      if (match != null) {
        members.add(match[1]!);
      } else if (line.trim().isNotEmpty && !line.startsWith(' ')) {
        break;
      }
    }
  }
  return members;
}

bool usesFlutter(String member) {
  final pubspec = File('$member/pubspec.yaml').readAsStringSync();
  return RegExp(r'^\s+sdk:\s*flutter\s*$', multiLine: true).hasMatch(pubspec);
}

Future<int> run(String member, IOSink log) async {
  final flutter = usesFlutter(member);
  final root = fromRoot.contains(member);
  final executable = flutter ? 'flutter' : Platform.resolvedExecutable;
  final arguments = ['test', '--concurrency=1', if (root) '$member/test'];
  log.writeln(
    '\$ ${flutter ? 'flutter' : 'dart'} ${arguments.join(' ')}'
    ' (in ${root ? '.' : member})',
  );
  final process = await Process.start(
    executable,
    arguments,
    workingDirectory: root ? '.' : member,
    runInShell: flutter && Platform.isWindows,
  );
  final output = [
    process.stdout.listen(log.add).asFuture<void>(),
    process.stderr.listen(log.add).asFuture<void>(),
  ];
  final timer = Timer(suiteTimeout, () {
    log.writeln('Timed out after ${suiteTimeout.inMinutes} minutes.');
    process.kill();
  });
  final code = await process.exitCode;
  timer.cancel();
  await Future.wait(output);
  return code;
}

Future<void> main(List<String> args) async {
  var shard = 1;
  var shards = 1;
  Set<String>? only;
  for (var i = 0; i < args.length; i++) {
    switch (args[i]) {
      case '--shard':
        final parts = args[++i].split('/');
        shard = int.parse(parts[0]);
        shards = int.parse(parts[1]);
      case '--only':
        only = args[++i].split(',').toSet();
      case '--list':
        only = {};
    }
  }
  final suites = [
    for (final member in workspaceMembers())
      if (Directory('$member/test').existsSync()) member,
  ];
  final selected = <String>[
    for (var i = 0; i < suites.length; i++)
      if (i % shards == shard - 1 &&
          (only == null ||
              only.isEmpty ||
              only.contains(suites[i]) ||
              only.contains(suites[i].split('/').last)))
        suites[i],
  ];
  if (only != null && only.isEmpty) {
    for (final suite in selected) {
      stdout.writeln(
        '$suite${skipped.containsKey(suite) ? ' (skipped: ${skipped[suite]})' : ''}',
      );
    }
    return;
  }

  final logs = Directory('build/test-logs')..createSync(recursive: true);
  final failures = <String, String>{};
  final watch = Stopwatch()..start();
  for (final suite in selected) {
    final reason = skipped[suite];
    if (reason != null) {
      stdout.writeln('SKIP  $suite: $reason');
      continue;
    }
    final file = File('${logs.path}/${suite.replaceAll('/', '_')}.log');
    final log = file.openWrite();
    final started = watch.elapsed;
    final code = await run(suite, log);
    await log.close();
    final seconds = (watch.elapsed - started).inSeconds;
    final summary = file
        .readAsLinesSync()
        .lastWhere(
          (line) => line.contains(RegExp(r'tests passed|tests failed')),
          orElse: () => 'exit code $code',
        )
        .trim();
    stdout.writeln(
      '${code == 0 ? 'PASS' : 'FAIL'}  $suite  ${seconds}s  $summary',
    );
    if (code != 0) failures[suite] = file.path;
  }
  stdout.writeln(
    'Ran ${selected.length - selected.where(skipped.containsKey).length} '
    'suites in ${watch.elapsed.inMinutes} minutes; ${failures.length} failed.',
  );
  for (final failure in failures.entries) {
    final lines = File(failure.value).readAsLinesSync();
    stdout
      ..writeln('\n=== ${failure.key} (last 60 lines of ${failure.value})')
      ..writeln(
        lines.skip(lines.length > 60 ? lines.length - 60 : 0).join('\n'),
      );
  }
  if (failures.isNotEmpty) exitCode = 1;
}
