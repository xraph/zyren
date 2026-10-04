import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';

import 'support/delayed_worker.dart';

void main() {
  test(
    'zero wait batches one sensor cohort without an awaited flush',
    () async {
      final backend = DelayedWorker();
      final model = fakeManifest();
      final cache = MlModelCache(
        worker: backend,
        resolver: (_) async => Uint8List.fromList([7]),
      );
      final scheduler = MlScheduler(
        cache: cache,
        currentTick: () => 1,
        batchWait: Duration.zero,
      );
      addTearDown(scheduler.close);
      final receipt = scheduler.batches.first;
      final first = scheduler.submit(request('first', model, value: 1));
      final cancelled = scheduler.submit(request('cancelled', model, value: 2));
      final last = scheduler.submit(request('last', model, value: 3));
      scheduler.cancel('cancelled');
      await backend.started.future;
      expect(backend.runs, 1);
      expect(scheduler.diagnostics.queuedRequests, 0);
      backend.finish();
      final batch = await receipt;
      expect(batch.map.slotRequestIds, ['first', 'last']);
      expect((await first).tensors['action']!.float32Values, [1, 1]);
      expect((await cancelled).status, MlOutcomeStatus.cancelled);
      expect((await last).tensors['action']!.float32Values, [3, 3]);
      await scheduler.close();
      expect(scheduler.diagnostics.inFlightBatches, 0);
      expect(scheduler.diagnostics.queuedTensorBytes, 0);
    },
  );
  test(
    'bounded byte admission stays constant under repeated backpressure',
    () async {
      final backend = DelayedWorker();
      final model = fakeManifest();
      final cache = MlModelCache(
        worker: backend,
        resolver: (_) async => Uint8List.fromList([7]),
      );
      final scheduler = MlScheduler(
        cache: cache,
        currentTick: () => 1,
        maxQueuedRequests: 64,
        maxQueuedBytes: 16,
        batchWait: const Duration(milliseconds: 100),
      );
      addTearDown(scheduler.close);
      final first = scheduler.submit(request('kept', model));
      for (var i = 0; i < 1000; i++) {
        expect(
          (await scheduler.submit(request('rejected-$i', model))).status,
          MlOutcomeStatus.capacity,
        );
        expect(scheduler.diagnostics.queuedTensorBytes, 16);
        expect(scheduler.diagnostics.queuedRequests, 1);
      }
      scheduler.cancel('kept');
      expect((await first).status, MlOutcomeStatus.cancelled);
      expect(scheduler.diagnostics.queuedTensorBytes, 0);
    },
  );
  test(
    'native completions past tick deadlines retain metadata but no tensors',
    () async {
      final backend = DelayedWorker();
      final model = fakeManifest();
      final cache = MlModelCache(
        worker: backend,
        resolver: (_) async => Uint8List.fromList([7]),
      );
      var tick = 1;
      final scheduler = MlScheduler(cache: cache, currentTick: () => tick);
      addTearDown(scheduler.close);
      final output = scheduler.submit(request('a', model, deadlineTick: 4));
      final flushing = scheduler.flush();
      await backend.started.future;
      tick = 5;
      backend.finish();
      await flushing;
      final result = await output;
      expect(result.status, MlOutcomeStatus.expired);
      expect(result.completedTick, 5);
      expect(result.deadlineTick, 4);
      expect(result.tensors, isEmpty);
    },
  );
  test(
    'queue count/bytes reject admission and expired ticks never run',
    () async {
      final backend = DelayedWorker();
      final model = fakeManifest();
      final cache = MlModelCache(
        worker: backend,
        resolver: (_) async => Uint8List.fromList([7]),
      );
      var tick = 10;
      final scheduler = MlScheduler(
        cache: cache,
        currentTick: () => tick,
        maxQueuedRequests: 1,
        maxQueuedBytes: 16,
        batchWait: const Duration(milliseconds: 20),
      );
      addTearDown(scheduler.close);
      final expired = await scheduler.submit(
        request('old', model, deadlineTick: 9),
      );
      expect(expired.status, MlOutcomeStatus.expired);
      final a = scheduler.submit(request('a', model));
      expect(
        (await scheduler.submit(request('overflow', model))).status,
        MlOutcomeStatus.capacity,
      );
      tick = 200;
      await scheduler.flush();
      expect((await a).status, MlOutcomeStatus.expired);
      expect(backend.runs, 0);
    },
  );

  test(
    'cancelled middle slot keeps the final actor on its original native row',
    () async {
      final backend = DelayedWorker();
      final model = fakeManifest();
      final cache = MlModelCache(
        worker: backend,
        resolver: (_) async => Uint8List.fromList([7]),
      );
      final scheduler = MlScheduler(
        cache: cache,
        currentTick: () => 1,
        batchWait: const Duration(milliseconds: 20),
      );
      addTearDown(scheduler.close);
      final receipt = scheduler.batches.first;
      final a = scheduler.submit(request('a', model, value: 1));
      final b = scheduler.submit(request('b', model, value: 2));
      final c = scheduler.submit(request('c', model, value: 3));
      final flushing = scheduler.flush();
      await backend.started.future;
      scheduler.cancel('b');
      backend.finish();
      await flushing;
      final batch = await receipt;
      expect(batch.map.slotRequestIds, ['a', 'c']);
      expect(batch.map.nativeSlotIndices, [0, 2]);
      expect(batch.results.keys, unorderedEquals(['a', 'c']));
      expect(batch.results.containsKey('b'), isFalse);
      expect((await a).tensors['action']!.float32Values, [1, 1]);
      expect((await b).status, MlOutcomeStatus.cancelled);
      expect((await c).tensors['action']!.float32Values, [3, 3]);
    },
  );

  test('out of order backend completions preserve request metadata', () async {
    final backend = DelayedWorker(outOfOrder: true);
    final model = fakeManifest();
    final cache = MlModelCache(
      worker: backend,
      resolver: (_) async => Uint8List.fromList([7]),
    );
    final scheduler = MlScheduler(
      cache: cache,
      currentTick: () => 3,
      maxBatchSlots: 1,
      maxInFlightBatches: 2,
      batchWait: const Duration(milliseconds: 20),
    );
    addTearDown(scheduler.close);
    final a = scheduler.submit(request('a', model, value: 1));
    final c = scheduler.submit(request('c', model, value: 3));
    final flushing = scheduler.flush();
    await backend.twoStarted.future;
    backend.finishFor('c');
    final second = await c;
    expect(second.requestId, 'c');
    expect(second.actorToken, 'actor-c');
    expect(second.modelHash, model.sha256);
    expect(second.observationTick, 1);
    expect(second.applicationTick, 4);
    expect(second.completedTick, 3);
    backend.finishFor('a');
    expect((await a).requestId, 'a');
    await flushing;
    expect(scheduler.diagnostics.queuedRequests, 0);
    expect(scheduler.diagnostics.inFlightBatches, 0);
  });
}
