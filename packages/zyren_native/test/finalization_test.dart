import 'dart:io';
import 'package:zyren_native/src/bindings.dart' as native;
import 'package:zyren_native/src/worker.dart';
import 'package:zyren_native/src/worker_session.dart';
import 'package:test/test.dart';

void main() {
  test(
    'worker teardown releases its GPU handle without a dispose request',
    () async {
      final baseline = native.liveRendererCount();
      final worker = await WorkerSession.start(renderWorker);
      expect(native.liveRendererCount(), baseline + 1);
      worker.abort();
      final timeout = Stopwatch()..start();
      while (native.liveRendererCount() != baseline &&
          timeout.elapsed < const Duration(seconds: 5)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(native.liveRendererCount(), baseline);
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
