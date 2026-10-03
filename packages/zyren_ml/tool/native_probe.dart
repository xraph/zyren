import 'dart:convert';
import 'dart:io';

import 'package:zyren_ml/zyren_ml.dart';

/// Run from packages/zyren_ml. Prints process RSS and native handle diagnostics.
Future<void> main() async {
  const runtime = MlRuntime();
  final rssBefore = ProcessInfo.currentRss;
  final values =
      jsonDecode(await File('test/fixtures/linear.values.json').readAsString())
          as Map<String, dynamic>;
  final input = values['inputs']['observation'] as Map<String, dynamic>;
  final manifest = MlModelManifest.decode(
    await File('test/fixtures/linear.json').readAsString(),
  );
  for (var i = 0; i < 100; i++) {
    final session = await runtime.load(
      manifest,
      (path) => File('test/fixtures/$path').readAsBytes(),
    );
    try {
      final result = await session.run({
        'observation': MlTensor.float32(
          (input['shape'] as List).cast<int>(),
          (input['values'] as List).cast<num>(),
        ),
      });
      if (result.status != MlRunStatus.ok ||
          result.tensors['action']!.float32Values.first != 30.5) {
        throw StateError('Real native inference failed: ${result.message}');
      }
    } finally {
      await session.close();
    }
  }
  final diagnostic = runtime.diagnostics;
  if (diagnostic.liveSessions != 0 || diagnostic.liveResults != 0) {
    throw StateError('Native handles remain live after close.');
  }
  stdout.writeln(
    jsonEncode({
      'schemaVersion': 1,
      'runtime': MlRuntime.runtimeVersion,
      'provider': 'cpu',
      'os': Platform.operatingSystem,
      'cycles': 100,
      'liveSessions': diagnostic.liveSessions,
      'liveResults': diagnostic.liveResults,
      'processRssBefore': rssBefore,
      'processRssAfter': ProcessInfo.currentRss,
      'nativeAllocatedBytes': null,
      'gpuResidentBytes': null,
      'scope':
          'Process RSS includes the Dart VM and ORT caches; it is not a native allocation measurement.',
    }),
  );
}
