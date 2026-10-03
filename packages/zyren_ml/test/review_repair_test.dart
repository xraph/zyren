import 'dart:async';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'support/delayed_worker.dart';

void main() {
  test('invalid actor row cannot poison a valid batched peer', () async {
    final backend = DelayedWorker();
    final model = fakeManifest();
    final scheduler = MlScheduler(
      cache: MlModelCache(
        worker: backend,
        resolver: (_) async => Uint8List.fromList([7]),
      ),
      currentTick: () => 1,
    );
    addTearDown(scheduler.close);
    final bad = scheduler.submit(request('bad', model, value: double.nan));
    final good = scheduler.submit(request('good', model, value: 4));
    final flushing = scheduler.flush();
    await backend.started.future;
    backend.finish();
    await flushing;
    expect((await bad).status, MlOutcomeStatus.invalid);
    expect((await good).status, MlOutcomeStatus.ok);
    expect((await good).tensors['action']!.float32Values, [4, 4]);
  });
  test(
    'batch propagates latest finite deadline, mixed batches stay unbounded',
    () async {
      final model = fakeManifest();
      for (final unbounded in [false, true]) {
        final backend = DelayedWorker();
        final scheduler = MlScheduler(
          cache: MlModelCache(
            worker: backend,
            resolver: (_) async => Uint8List.fromList([7]),
          ),
          currentTick: () => 1,
        );
        final late = DateTime.now().add(const Duration(minutes: 1));
        MlRequest actor(String id, DateTime? deadline) => MlRequest(
          id: id,
          model: model,
          modelHash: model.sha256,
          actorToken: id,
          observationTick: 1,
          applicationTick: 2,
          deadlineTick: 100,
          deadline: deadline,
          tensors: request(id, model).tensors,
        );
        final a = scheduler.submit(
          actor('a', DateTime.now().add(const Duration(seconds: 10))),
        );
        final b = scheduler.submit(actor('b', unbounded ? null : late));
        final flushing = scheduler.flush();
        await backend.started.future;
        expect(
          backend.pendingOptions.single.deadline,
          unbounded ? isNull : late,
        );
        backend.finish();
        await flushing;
        await a;
        await b;
        await scheduler.close();
      }
    },
  );
  test('spawn failure propagates once and close remains idempotent', () async {
    final uncaught = <Object>[];
    await runZonedGuarded(() async {
      final worker = MlWorker(
        spawner: (_, _) async => throw StateError('injected spawn failure'),
      );
      await expectLater(worker.diagnostics(), throwsStateError);
      await Future<void>.delayed(Duration.zero);
      expect(
        (await worker.diagnostics()).failureReason,
        contains('injected spawn failure'),
      );
      await worker.close();
      await worker.close();
    }, (error, _) => uncaught.add(error));
    expect(uncaught, isEmpty);
  });
  test(
    'batch row extraction copies only owned row data with immutable storage',
    () {
      final batch = MlTensor.float32([64, 16], List.generate(1024, (i) => i));
      final rows = [
        for (var i = 0; i < 64; i++) batch.batchRow(i, expectedRows: 64),
      ];
      expect(rows.fold<int>(0, (n, t) => n + t.byteLength), batch.byteLength);
      expect(
        rows.last.float32Values,
        List.generate(16, (i) => (1008 + i).toDouble()),
      );
      rows.last.bytes.fillRange(0, rows.last.byteLength, 0);
      expect(rows.last.float32Values.first, 1008);
      expect(() => batch.batchRow(0, expectedRows: 63), throwsStateError);
    },
  );
}
