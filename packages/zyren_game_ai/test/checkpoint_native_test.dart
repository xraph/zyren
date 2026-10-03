import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'policy_test.dart' show PolicyFixture;

void main() {
  test(
    'native recurrent continuation matches after pause and fresh-handle restore',
    () async {
      final f = PolicyFixture();
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/lstm_step.json').readAsStringSync(),
      );
      var tick = 1;
      final cache = MlModelCache(
        resolver: (_) =>
            File('../zyren_ml/test/fixtures/lstm_step.onnx').readAsBytes(),
      );
      final ml = MlScheduler(cache: cache, currentTick: () => tick);
      final actor = f.entities.spawn('actor');
      final brain = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: actor,
          modelHash: model.sha256,
        ),
        contract: f.contract(model, ActionDecoder.character()),
        ml: ml,
        entities: f.entities,
      );
      Future<BrainDecision> step(
        PolicyBrain b, {
        int gameEpoch = 0,
        int controlEpoch = 0,
      }) async {
        b.observe(f.frame(b.identity, tick));
        final job = b.request(
          f.context(b, tick, gameEpoch: gameEpoch, controlEpoch: controlEpoch),
        );
        await ml.flush();
        final staged = (await job)!;
        tick = staged.applyTick;
        final decision = b.decide(
          f.context(b, tick, gameEpoch: gameEpoch, controlEpoch: controlEpoch),
        );
        expect(decision.isFallback, isFalse);
        return decision;
      }

      await step(brain);
      brain.synchronize(
        gameEpoch: 1,
        controlEpoch: 1,
        paused: true,
        preserveCommittedState: true,
      );
      await brain.quiesce();
      final checkpoint = PolicyBrainCheckpoint.decode(
        brain.snapshotCommitted(tick: tick).encode(),
      );
      final savedTick = tick;
      brain.synchronize(
        gameEpoch: 2,
        controlEpoch: 2,
        paused: false,
        preserveCommittedState: true,
      );
      tick++;
      final reference = await step(brain, gameEpoch: 2, controlEpoch: 2);
      final referenceHidden = brain.state.tensors.map(
        (k, v) => MapEntry(k, v.bytes),
      );
      await brain.quiesce();
      f.entities.despawn(actor);
      final fresh = f.entities.spawn('actor');
      tick = savedTick;
      brain.restoreCommitted(
        checkpoint,
        identity: BrainIdentity(
          episodeId: 'restored',
          entity: fresh,
          modelHash: model.sha256,
        ),
        tick: tick,
        gameEpoch: 4,
        controlEpoch: 3,
        paused: true,
        remap: (old) => old == actor ? fresh : null,
      );
      brain.synchronize(
        gameEpoch: 5,
        controlEpoch: 4,
        paused: false,
        preserveCommittedState: true,
      );
      tick++;
      final restored = await step(brain, gameEpoch: 5, controlEpoch: 4);
      expect(
        restored.policyAction!.continuous,
        reference.policyAction!.continuous,
      );
      for (final entry in referenceHidden.entries) {
        expect(brain.state.tensors[entry.key]!.bytes, entry.value);
      }
      expect(brain.state.version, 2);
      await brain.close();
      await ml.close();
      expect((await cache.worker.diagnostics()).liveSessions, 0);
    },
  );
}
