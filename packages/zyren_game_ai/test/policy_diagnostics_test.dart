import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_ml/test/support/delayed_worker.dart';
import 'policy_test.dart' show PolicyFixture;

void main() {
  test('rejected action outputs remain counted after a policy reset', () async {
    final fixture = PolicyFixture(), model = fakeManifest();
    fixture.sensor.values = [4, 0, 0, 0];
    final worker = DelayedWorker();
    final ml = MlScheduler(
      cache: MlModelCache(
        worker: worker,
        resolver: (_) async => Uint8List.fromList([7]),
      ),
      currentTick: () => 1,
    );
    final brain = PolicyBrain(
      identity: BrainIdentity(
        episodeId: 'diagnostics',
        entity: fixture.entities.spawn('npc'),
        modelHash: model.sha256,
      ),
      contract: fixture.contract(model, ActionDecoder.character()),
      ml: ml,
      entities: fixture.entities,
    );
    try {
      brain.observe(fixture.frame(brain.identity, 1));
      final requested = brain.request(fixture.context(brain, 1));
      final flushed = ml.flush();
      await worker.started.future;
      worker.finish();
      await flushed;
      expect(await requested, isNull);
      expect(brain.invalidOutputs, 1);
      expect(brain.state.version, 0);
      brain.invalidatePending();
      expect(brain.invalidOutputs, 1);
    } finally {
      await brain.close();
      await ml.close();
    }
  });
}
