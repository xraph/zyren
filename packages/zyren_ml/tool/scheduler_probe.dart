import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:zyren_ml/zyren_ml.dart';

Future<void> main() async {
  final worker = MlWorker();
  final cache = MlModelCache(
    worker: worker,
    resolver: (path) => File('test/fixtures/$path').readAsBytes(),
  );
  final scheduler = MlScheduler(
    cache: cache,
    currentTick: () => 1,
    maxQueuedRequests: 2,
    maxQueuedBytes: 32,
    batchWait: const Duration(milliseconds: 20),
  );
  final model = MlModelManifest.decode(
    await File('test/fixtures/linear.json').readAsString(),
  );
  MlRequest request(String id) => MlRequest(
    id: id,
    model: model,
    modelHash: model.sha256,
    tensors: {
      'observation': MlTensor.float32([1, 4], [1, 2, 3, 4]),
    },
    actorToken: id,
    observationTick: 1,
    applicationTick: 2,
    deadlineTick: 2,
  );
  final rssBefore = ProcessInfo.currentRss;
  var peakQueuedBytes = 0, rejected = 0;
  final timings = <Map<String, Object>>[];
  try {
    for (var round = 0; round < 3; round++) {
      final a = scheduler.submit(request('$round-a'));
      final b = scheduler.submit(request('$round-b'));
      for (var i = 0; i < 1000; i++) {
        if ((await scheduler.submit(request('$round-rejected-$i'))).status !=
            MlOutcomeStatus.capacity) {
          throw StateError(
            'Backpressure admitted a request beyond its budget.',
          );
        }
        rejected++;
        final bytes = scheduler.diagnostics.queuedTensorBytes;
        if (bytes > peakQueuedBytes) peakQueuedBytes = bytes;
      }
      await scheduler.flush();
      for (final output in await Future.wait([a, b])) {
        if (output.status != MlOutcomeStatus.ok ||
            output.tensors['action']!.float32Values.first != 30.5) {
          throw StateError('Worker native inference failed: ${output.message}');
        }
        timings.add({
          'requestId': output.requestId,
          'cold': output.timing.cold,
          'queueUs': output.timing.queue.inMicroseconds,
          'modelLoadUs': output.timing.modelLoad.inMicroseconds,
          'nativeRunUs': output.timing.nativeRun.inMicroseconds,
          'workerRoundTripUs': output.timing.workerRoundTrip.inMicroseconds,
        });
      }
    }
  } finally {
    await scheduler.close();
  }
  final native = await worker.diagnostics();
  stdout.writeln(
    jsonEncode({
      'schemaVersion': 1,
      'runtime': MlRuntime.runtimeVersion,
      'provider': 'cpu',
      'os': Platform.operatingSystem,
      'rejectedRequests': rejected,
      'peakQueuedTensorBytes': peakQueuedBytes,
      'liveSessions': native.liveSessions,
      'liveResults': native.liveResults,
      'processRssBefore': rssBefore,
      'processRssAfter': ProcessInfo.currentRss,
      'nativeArenaBytes': null,
      'recurrentStateBytes': null,
      'sensorBytes': null,
      'timings': timings,
      'scope':
          'Three host-isolate scheduling runs and 3000 rejected admissions. RSS includes VM/ORT caches; this is not device capacity qualification.',
    }),
  );
}
