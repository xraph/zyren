import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_ml/test/support/delayed_worker.dart';
import 'policy_test.dart' show PolicyFixture;

void main() {
  test(
    'sensor-owned submission leaves the next observation slot free',
    () async {
      final fixture = PolicyFixture(), model = fakeManifest();
      final worker = DelayedWorker();
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => tick,
      );
      final group = PolicyGroup(
        episodeId: 'sensor-owned',
        entities: fixture.entities,
        ml: ml,
      );
      final identity = BrainIdentity(
        episodeId: group.episodeId,
        entity: fixture.entities.spawn('npc'),
        modelHash: model.sha256,
      );
      final contract = fixture.contract(model, ActionDecoder.character());
      var brain = group.join(identity, contract, autoRequest: false);
      try {
        brain.observe(fixture.frame(identity, tick));
        final requested = brain.request(fixture.context(brain, tick));
        final flushed = ml.flush();
        await worker.started.future;
        worker.finish();
        await flushed;
        expect(await requested, isNotNull);
        tick = 3;
        expect(brain.decide(fixture.context(brain, tick)).isFallback, isFalse);
        expect(brain.activeRequest, isNull);
        expect(ml.diagnostics.queuedRequests, 0);
        expect(brain.state.version, 1);
        await group.selectModel(identity.entity, contract);
        brain = group.brainFor(identity.entity)!;
        expect(brain.autoRequest, isFalse);
        brain.observe(fixture.frame(identity, tick));
        brain.decide(fixture.context(brain, tick));
        expect(brain.activeRequest, isNull);
        final fresh = brain.request(fixture.context(brain, tick));
        final freshFlush = ml.flush();
        await worker.twoStarted.future;
        expect(brain.activeRequest!.observationTick, 3);
        worker.finishAt(1);
        await freshFlush;
        expect(await fresh, isNotNull);
      } finally {
        await group.close();
        await ml.close();
      }
    },
  );
}
