import 'dart:convert';
import 'dart:io';

Future<void> saveNavigationDeviceReport(
  Directory output,
  String runId,
  Map<String, Object?> report,
) async {
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,80}$').hasMatch(runId)) {
    throw ArgumentError('Use a short run ID with letters, digits or hyphens.');
  }
  await output.create(recursive: true);
  final destination = File('${output.path}/$runId.json');
  if (await destination.exists()) {
    throw StateError('Use a new run ID to preserve the previous report.');
  }
  final pending = File('${destination.path}.pending');
  await pending.writeAsString(
    jsonEncode({
      ...report,
      'runId': runId,
      'exportedAt': DateTime.now().toUtc().toIso8601String(),
      'cpuProfileStatus': 'unavailable',
      'cpuProfileError': 'Device export does not collect VM CPU samples.',
    }),
    flush: true,
  );
  await pending.rename(destination.path);
}
