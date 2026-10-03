import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_ml/test/support/delayed_worker.dart' show DelayedWorker;
import 'policy_test.dart' show PolicyFixture, ProbeEncoder;

final class LogitsWorker implements MlInferenceWorker {
  final delegate = DelayedWorker();
  @override
  Future<Duration> load(MlModelManifest model, Uint8List bytes) =>
      delegate.load(model, bytes);
  @override
  Future<MlRunResult> run(
    String hash,
    MlTensorMap tensors,
    MlRunOptions options,
  ) async {
    final values = List<double>.filled(22, 0);
    values[19] = 10; // Jump branch choice1, admitted only by the captured mask.
    return MlRunResult(
      MlRunStatus.ok,
      tensors: {
        'logits': MlTensor.float32([1, 22], values),
      },
    );
  }

  @override
  Future<void> release(String hash) => delegate.release(hash);
  @override
  Future<MlWorkerDiagnostics> diagnostics() => delegate.diagnostics();
  @override
  Future<void> close() => delegate.close();
}

void main() {
  test(
    'discrete-only inference binds no zero-width tensor and rechecks live masks',
    () async {
      final fixture = PolicyFixture(), worker = LogitsWorker();
      final model = MlModelManifest(
        id: 'character-discrete',
        modelFile: 'model.onnx',
        sha256: sha256.convert([7]).toString(),
        opset: 17,
        inputs: [
          MlTensorSpec(
            name: 'observation',
            dtype: MlDtype.float32,
            shape: [-1, 4],
            maxShape: [8, 4],
          ),
        ],
        outputs: [
          MlTensorSpec(
            name: 'logits',
            dtype: MlDtype.float32,
            shape: [-1, 22],
            maxShape: [8, 22],
          ),
        ],
      );
      final decoder = ActionDecoder.characterDiscrete();
      PolicyContract make({String? output}) => PolicyContract(
        model: model,
        observation: fixture.assembler.spec,
        decoder: decoder,
        continuousOutput: output,
        discreteOutput: 'logits',
        encoder: const ProbeEncoder(),
        latencyTicks: 2,
      );
      expect(() => make(output: 'action'), throwsArgumentError);
      final contract = make();
      expect(contract.toJson()['continuousOutput'], isNull);
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
      final actor = fixture.entities.spawn('actor');
      final brain = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: actor,
          modelHash: model.sha256,
        ),
        contract: contract,
        ml: ml,
        entities: fixture.entities,
      );
      addTearDown(brain.close);
      List<List<bool>> masks() => [
        for (final branch in decoder.spec.branches)
          List.filled(branch.choices.length, true),
      ];
      final captured = masks();
      BrainContext context(List<List<bool>> legal) => BrainContext(
        identity: brain.identity,
        tick: tick,
        beliefs: [],
        goals: [],
        actionSpec: decoder.spec,
        legality: legal,
      );
      brain.observe(fixture.frame(brain.identity, tick));
      final pending = brain.request(context(captured), legality: captured);
      await ml.flush();
      final staged = await pending;
      expect(staged!.policyAction!.continuous, isEmpty);
      expect(staged.policyAction!.discrete[4], 1);
      tick = 3;
      final execution = masks()..[4][1] = false;
      expect(brain.decide(context(execution)).isFallback, isTrue);
      expect(brain.state.version, 0);
      expect(brain.decisions.currentAction.character!.jump, isFalse);
      tick = 4;
      brain.observe(fixture.frame(brain.identity, tick));
      final fresh = brain.request(context(execution), legality: execution);
      await ml.flush();
      expect((await fresh)!.policyAction!.discrete[4], 0);
      tick = 6;
      expect(brain.decide(context(execution)).isFallback, isFalse);
      expect(brain.state.version, 1);
    },
  );
}
