import 'dart:convert';
import 'dart:io';

Future<Map<String, dynamic>> saveNavigationReport({
  required Directory output,
  required Map<String, dynamic> report,
  required Future<Map<String, dynamic>> Function() captureCpu,
  Duration cpuTimeout = const Duration(seconds: 10),
}) async {
  final raw = Map<String, dynamic>.from(report)
    ..['cpuProfileStatus'] = 'pending';
  Map<String, dynamic> save() {
    File('${output.path}/frames.json').writeAsStringSync(jsonEncode(raw));
    final summary = jsonDecode(jsonEncode(raw)) as Map<String, dynamic>;
    for (final phase in summary['phases'] as List) {
      final samples = phase.remove('samples') as List;
      phase['framesWhileLoading'] = samples
          .where((s) => (s['loading'] as int) > 0)
          .length;
      phase['framesBudgetLimited'] = samples
          .where((s) => s['budgetLimited'] == true)
          .length;
      phase['uploadedBytes'] = samples.fold<int>(
        0,
        (sum, s) => sum + (s['uploadedBytes'] as int),
      );
      phase['cloudHistoryResets'] = samples
          .where((s) => s['cloudReset'] != 'none')
          .length;
    }
    File('${output.path}/summary.json').writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(summary)}\n',
    );
    return summary;
  }

  save();
  try {
    final cpu = await captureCpu().timeout(cpuTimeout);
    File('${output.path}/cpu-samples.json').writeAsStringSync(jsonEncode(cpu));
    raw['cpuSampleCount'] = cpu['sampleCount'];
    raw['cpuCaptureWindow'] = cpu['captureWindow'];
    raw['cpuProfileStatus'] = 'captured';
  } catch (error) {
    raw['cpuProfileError'] = error.runtimeType.toString();
    raw['cpuProfileStatus'] = 'unavailable';
  }
  return save();
}
