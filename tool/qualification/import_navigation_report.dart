import 'dart:convert';
import 'dart:io';

import 'navigation_benchmark_capture.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    throw ArgumentError(
      'Pass an exported device report and an empty output directory.',
    );
  }
  final report =
      jsonDecode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  if (report['suite'] != 'live-google-navigation' || report['schema'] != 1) {
    throw ArgumentError('Unsupported navigation report.');
  }
  final output = Directory(args[1]);
  if (output.existsSync() && output.listSync().isNotEmpty) {
    throw StateError(
      'Use an empty output directory to preserve prior measurements.',
    );
  }
  output.createSync(recursive: true);
  final summary = await saveNavigationReport(
    output: output,
    report: report,
    captureCpu: () async =>
        throw UnsupportedError('Device export has no VM CPU samples.'),
  );
  stdout.writeln(jsonEncode(summary));
  if (summary['passed'] != true) exitCode = 1;
}
