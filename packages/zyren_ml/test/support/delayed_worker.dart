import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:zyren_ml/zyren_ml.dart';

MlModelManifest fakeManifest({int byte = 7, String id = 'probe'}) =>
    MlModelManifest(
      id: id,
      modelFile: '$id.onnx',
      sha256: sha256.convert([byte]).toString(),
      opset: 17,
      inputs: [
        MlTensorSpec(
          name: 'observation',
          dtype: MlDtype.float32,
          shape: [-1, 4],
          maxShape: [64, 4],
        ),
      ],
      outputs: [
        MlTensorSpec(
          name: 'action',
          dtype: MlDtype.float32,
          shape: [-1, 2],
          maxShape: [64, 2],
        ),
      ],
    );
MlRequest request(
  String id,
  MlModelManifest model, {
  int deadlineTick = 100,
  double value = 1,
}) => MlRequest(
  id: id,
  model: model,
  modelHash: model.sha256,
  actorToken: 'actor-$id',
  observationTick: 1,
  applicationTick: 4,
  deadlineTick: deadlineTick,
  tensors: {
    'observation': MlTensor.float32([1, 4], [value, 0, 0, 0]),
  },
);

final class DelayedWorker implements MlInferenceWorker {
  DelayedWorker({this.outOfOrder = false});
  final bool outOfOrder;
  final started = Completer<void>();
  final twoStarted = Completer<void>();
  final pending = <Completer<void>>[];
  final pendingIds = <String?>[];
  final loaded = <String>{};
  var runs = 0;
  var closes = 0;
  var loads = 0;
  void finish() => finishAt(0);
  void finishAt(int index) => pending[index].complete();
  void finishFor(String id) => finishAt(pendingIds.indexOf(id));
  @override
  Future<Duration> load(MlModelManifest model, Uint8List bytes) async {
    loaded.add(model.sha256);
    loads++;
    return const Duration(microseconds: 10);
  }

  @override
  Future<MlRunResult> run(
    String hash,
    MlTensorMap tensors,
    MlRunOptions options,
  ) async {
    final gate = Completer<void>();
    pending.add(gate);
    pendingIds.add(options.requestId);
    runs++;
    if (!started.isCompleted) started.complete();
    if (runs == 2 && !twoStarted.isCompleted) twoStarted.complete();
    await gate.future;
    final input = tensors['observation']!;
    final n = input.shape.first;
    return MlRunResult(
      MlRunStatus.ok,
      tensors: {
        'action': MlTensor.float32(
          [n, 2],
          [
            for (var i = 0; i < n; i++) ...[
              input.float32Values[i * 4],
              input.float32Values[i * 4],
            ],
          ],
        ),
      },
      elapsed: const Duration(milliseconds: 1),
    );
  }

  @override
  Future<void> release(String hash) async {
    loaded.remove(hash);
    closes++;
  }

  @override
  Future<MlWorkerDiagnostics> diagnostics() async => MlWorkerDiagnostics(
    residentModels: loaded.length,
    liveSessions: loaded.length,
    liveResults: 0,
  );
  @override
  Future<void> close() async {
    loaded.clear();
    closes++;
  }
}
