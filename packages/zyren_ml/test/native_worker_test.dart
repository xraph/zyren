import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';

MlModelManifest model(String name) =>
    MlModelManifest.decode(File('test/fixtures/$name.json').readAsStringSync());
Future<Uint8List> resolve(String path) =>
    File('test/fixtures/$path').readAsBytes();
MlRequest actor(String id, MlModelManifest manifest, MlTensor tensor) =>
    MlRequest(
      id: id,
      model: manifest,
      modelHash: manifest.sha256,
      tensors: {'observation': tensor},
      actorToken: 'episode-1/$id/generation-1',
      observationTick: 1,
      applicationTick: 2,
      deadlineTick: 100,
    );

Future<void> waitNativeActive() async {
  final timeout = Stopwatch()..start();
  while (const MlRuntime().diagnostics.activeRuns == 0) {
    if (timeout.elapsed > const Duration(seconds: 10)) {
      throw StateError('Real native inference did not start.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

MlTensor matrix(double value) {
  final bytes = Uint8List(1024 * 1024 * 4);
  final data = ByteData.sublistView(bytes);
  for (var i = 0; i < 1024 * 1024; i++) {
    data.setFloat32(i * 4, value, Endian.little);
  }
  return MlTensor(MlDtype.float32, [1, 1024, 1024], bytes);
}

void main() {
  test(
    'real worker batches actors and keeps all native handles in another isolate',
    () async {
      final worker = MlWorker();
      final cache = MlModelCache(worker: worker, resolver: resolve);
      final scheduler = MlScheduler(
        cache: cache,
        currentTick: () => 1,
        batchWait: const Duration(milliseconds: 20),
      );
      final manifest = model('linear');
      final a = scheduler.submit(
        actor('a', manifest, MlTensor.float32([1, 4], [1, 2, 3, 4])),
      );
      final c = scheduler.submit(
        actor('c', manifest, MlTensor.float32([1, 4], [2, 0, 0, 0])),
      );
      await scheduler.flush();
      expect((await a).tensors['action']!.float32Values, [30.5, 1.5]);
      expect((await c).tensors['action']!.float32Values, [2.5, -2.5]);
      final diagnostics = await worker.diagnostics();
      expect(
        diagnostics.ownerIsolateId,
        isNot(Isolate.current.hashCode.toString()),
      );
      expect(diagnostics.residentModels, 1);
      expect(diagnostics.liveResults, 0);
      await scheduler.close();
      expect((await worker.diagnostics()).liveSessions, 0);
    },
  );

  test(
    'cancelled native middle slot retains row 2 and shutdown waits for actual ORT completion',
    () async {
      final worker = MlWorker();
      final cache = MlModelCache(worker: worker, resolver: resolve);
      final scheduler = MlScheduler(
        cache: cache,
        currentTick: () => 1,
        batchWait: const Duration(milliseconds: 20),
      );
      final manifest = model('slow_matmul');
      final aInput = matrix(0.0001),
          bInput = matrix(0.0002),
          cInput = matrix(0.0003);
      final receipt = scheduler.batches.first;
      final before = const MlRuntime().diagnostics.completedRuns;
      var heartbeats = 0;
      final heartbeat = Timer.periodic(
        const Duration(milliseconds: 2),
        (_) => heartbeats++,
      );
      try {
        final a = scheduler.submit(actor('a', manifest, aInput));
        final b = scheduler.submit(actor('b', manifest, bInput));
        final c = scheduler.submit(actor('c', manifest, cInput));
        final running = scheduler.flush();
        await waitNativeActive();
        scheduler.cancel('b');
        expect(cache.diagnostics.inFlightReferences, 1);
        await running;
        final batch = await receipt;
        expect(batch.map.slotRequestIds, ['a', 'c']);
        expect(batch.map.nativeSlotIndices, [0, 2]);
        expect((await b).status, MlOutcomeStatus.cancelled);
        final first = (await a).tensors['action']!.float32Values.first;
        final last = (await c).tensors['action']!.float32Values.first;
        expect(
          first,
          closeTo(0.0001 * 0.1024 * 0.1024 * 0.1024 * 0.1024, 1e-7),
        );
        expect(last, closeTo(0.0003 * 0.3072 * 0.3072 * 0.3072 * 0.3072, 1e-7));
        expect(last, greaterThan(first));
        expect(heartbeats, greaterThan(5));
        expect(const MlRuntime().diagnostics.completedRuns, before + 1);
        expect((await worker.diagnostics()).liveResults, 0);
      } finally {
        heartbeat.cancel();
        await scheduler.close();
      }
      expect((await worker.diagnostics()).liveSessions, 0);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test(
    'dispose during actual native execution waits and suppresses the result',
    () async {
      final worker = MlWorker();
      final cache = MlModelCache(worker: worker, resolver: resolve);
      final scheduler = MlScheduler(cache: cache, currentTick: () => 1);
      final input = matrix(0.0001);
      final before = const MlRuntime().diagnostics.completedRuns;
      final result = scheduler.submit(
        actor('dispose', model('slow_matmul'), input),
      );
      final running = scheduler.flush();
      await waitNativeActive();
      var closed = false;
      final closing = scheduler.close().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      expect(const MlRuntime().diagnostics.liveSessions, greaterThan(0));
      await closing;
      await running;
      expect((await result).status, MlOutcomeStatus.cancelled);
      final diagnostic = await worker.diagnostics();
      expect(diagnostic.liveSessions, 0);
      expect(diagnostic.liveResults, 0);
      expect(diagnostic.completedRuns, before + 1);
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
