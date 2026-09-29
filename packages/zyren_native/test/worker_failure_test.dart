import 'dart:isolate';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/src/worker_session.dart';
import 'package:test/test.dart';

void exitBeforeReady(WorkerBootstrap start) {
  Isolate.exit();
}

void exitDuringRequest(WorkerBootstrap start) {
  final commands = ReceivePort();
  start.messages.send(WorkerReady(start.generation, commands.sendPort));
  commands.listen((_) => Isolate.exit());
}

void staleThenValid(WorkerBootstrap start) {
  final commands = ReceivePort();
  start.messages.send(WorkerReady(start.generation, commands.sendPort));
  commands.listen((dynamic value) {
    final request = value as WorkerRequest;
    start.messages.send(
      WorkerReply(request.id, request.generation - 1, true, 'stale'),
    );
    start.messages.send(
      WorkerReply(request.id, request.generation, true, request.operation),
    );
    start.messages.send(
      WorkerReply(request.id, request.generation, true, 'duplicate'),
    );
  });
}

void main() {
  test('exit during initialization settles startup', () async {
    await expectLater(
      WorkerSession.start(exitBeforeReady).timeout(const Duration(seconds: 5)),
      throwsA(
        isA<SceneException>().having(
          (e) => e.issue.code,
          'code',
          SceneIssueCodes.backendUnavailable,
        ),
      ),
    );
  });
  test(
    'worker exit settles every pending request and closes idempotently',
    () async {
      final worker = await WorkerSession.start(exitDuringRequest);
      final requests = [
        worker.request('first', []),
        worker.request('second', []),
      ];
      await Future.wait(
        requests.map(
          (request) => expectLater(
            request.timeout(const Duration(seconds: 5)),
            throwsA(
              isA<SceneException>().having(
                (e) => e.issue.code,
                'code',
                SceneIssueCodes.deviceLost,
              ),
            ),
          ),
        ),
      );
      await worker.close();
      await worker.close();
      await expectLater(
        worker.request('late', []),
        throwsA(isA<SceneException>()),
      );
    },
  );
  test(
    'stale generation and duplicate replies cannot settle another request',
    () async {
      final worker = await WorkerSession.start(staleThenValid);
      expect(await worker.request('first', []), 'first');
      expect(await worker.request('second', []), 'second');
      await worker.close();
    },
  );
}
