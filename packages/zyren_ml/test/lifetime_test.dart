import 'dart:typed_data';
import 'dart:async';

import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';

import 'support/delayed_worker.dart';

void main() {
  test(
    'idle sessions can be evicted only after their native jobs release',
    () async {
      final worker = DelayedWorker();
      final cache = MlModelCache(
        worker: worker,
        maxResidentModels: 1,
        resolver: (path) async =>
            Uint8List.fromList([path == 'other.onnx' ? 8 : 7]),
      );
      addTearDown(cache.close);
      final lease = await cache.acquire(fakeManifest());
      final run = lease.run(request('a', fakeManifest()).tensors);
      await worker.started.future;
      await cache.release(lease);
      expect(worker.closes, 0);
      worker.finish();
      await run;
      final next = await cache.acquire(fakeManifest(byte: 8, id: 'other'));
      expect(worker.closes, 1);
      expect(worker.loads, 2);
      expect(worker.loaded, [next.modelHash]);
      await cache.release(next);
    },
  );
  test(
    'close during model resolution aborts loading and joins the acquisition',
    () async {
      final worker = DelayedWorker();
      final source = Completer<Uint8List>();
      final resolving = Completer<void>();
      final cache = MlModelCache(
        worker: worker,
        resolver: (_) {
          resolving.complete();
          return source.future;
        },
      );
      final acquisition = cache.acquire(fakeManifest());
      await resolving.future;
      final closing = cache.close();
      source.complete(Uint8List.fromList([7]));
      await expectLater(
        acquisition,
        throwsA(
          isA<MlLoadException>().having(
            (e) => e.status,
            'status',
            MlRunStatus.unavailable,
          ),
        ),
      );
      await closing;
      expect(worker.loads, 0);
    },
  );
  test('in flight leases block eviction and close awaits completion', () async {
    final worker = DelayedWorker();
    final cache = MlModelCache(
      worker: worker,
      maxResidentModels: 1,
      resolver: (path) async =>
          Uint8List.fromList([path == 'other.onnx' ? 8 : 7]),
    );
    final lease = await cache.acquire(fakeManifest());
    final job = lease.run(request('a', fakeManifest()).tensors);
    await worker.started.future;
    await cache.release(lease);
    expect(cache.diagnostics.inFlightReferences, 1);
    await expectLater(
      cache.acquire(fakeManifest(byte: 8, id: 'other')),
      throwsA(isA<MlCapacityException>()),
    );
    expect(worker.loaded, [fakeManifest().sha256]);
    var closed = false;
    final closing = cache.close().then((_) => closed = true);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isFalse);
    worker.finish();
    expect((await job).status, MlRunStatus.ok);
    await closing;
    expect(worker.loaded, isEmpty);
  });

  test(
    'same pin shares one session; incompatible duplicate pin fails',
    () async {
      final worker = DelayedWorker();
      final cache = MlModelCache(
        worker: worker,
        resolver: (_) async => Uint8List.fromList([7]),
      );
      addTearDown(cache.close);
      final first = await cache.acquire(fakeManifest());
      final second = await cache.acquire(fakeManifest());
      expect(worker.loads, 1);
      await expectLater(
        cache.acquire(fakeManifest(id: 'different_contract')),
        throwsA(isA<MlLoadException>()),
      );
      await cache.release(first);
      await cache.release(second);
      expect(cache.diagnostics.residentModels, 1);
      expect(cache.diagnostics.leaseReferences, 0);
    },
  );

  test('oversized model fails before evicting the current session', () async {
    final worker = DelayedWorker();
    final cache = MlModelCache(
      worker: worker,
      maxResidentModels: 1,
      maxModelWeightsBytes: 1,
      resolver: (path) async =>
          Uint8List.fromList(path == 'other.onnx' ? [8, 9] : [7]),
    );
    addTearDown(cache.close);
    final lease = await cache.acquire(fakeManifest());
    await cache.release(lease);
    await expectLater(
      cache.acquire(fakeManifest(byte: 8, id: 'other')),
      throwsA(isA<MlCapacityException>()),
    );
    expect(worker.loads, 1);
    expect(worker.closes, 0);
    expect(cache.diagnostics.modelWeightsBytes, 1);
  });
}
