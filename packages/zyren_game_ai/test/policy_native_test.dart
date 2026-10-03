import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_game_native/test/support/character_fixture.dart';
import '../../zyren_game_native/test/support/vehicle_fixture.dart';
import 'policy_test.dart' show PolicyFixture;

void near(List<double> actual, List<dynamic> expected) {
  expect(actual.length, expected.length);
  for (var i = 0; i < actual.length; i++) {
    expect(actual[i], closeTo((expected[i] as num).toDouble(), 1e-5));
  }
}

void main() {
  test(
    'real recurrent completion jitter preserves the last committed state',
    () async {
      final f = PolicyFixture();
      final actor = f.entities.spawn('actor');
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/lstm_step.json').readAsStringSync(),
      );
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          resolver: (_) async =>
              File('../zyren_ml/test/fixtures/lstm_step.onnx').readAsBytes(),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
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
      addTearDown(brain.close);
      for (final jitter in [0, 1, 2, 0]) {
        brain.observe(f.frame(brain.identity, tick));
        final version = brain.state.version;
        final before = brain.state.tensors['hidden']!.float32Values;
        final pending = brain.request(f.context(brain, tick));
        await ml.flush();
        final candidate = await pending;
        expect(candidate, isNotNull);
        tick = candidate!.applyTick + jitter;
        final decision = brain.decide(f.context(brain, tick));
        expect(decision.isFallback, jitter != 0);
        expect(brain.state.version, version + (jitter == 0 ? 1 : 0));
        if (jitter != 0) {
          expect(brain.state.tensors['hidden']!.float32Values, before);
        }
        tick++;
      }
      expect(brain.decisions.receipts.map((r) => r.accepted), [
        true,
        false,
        false,
        true,
      ]);
    },
  );

  test(
    'real A1 1000-step recurrent sequence reaches character and vehicle decoders',
    () async {
      final f = PolicyFixture();
      final character = await GameCharacterFixture.create();
      final vehicle = await VehicleFixture.create();
      addTearDown(character.close);
      addTearDown(vehicle.close);
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/lstm_step.json').readAsStringSync(),
      );
      final sequence =
          jsonDecode(
                File(
                  '../zyren_ml/test/fixtures/lstm_sequence.values.json',
                ).readAsStringSync(),
              )
              as List;
      var tick = character.simulation.session.tick;
      expect(vehicle.simulation.session.tick, tick);
      final cache = MlModelCache(
        resolver: (_) async =>
            File('../zyren_ml/test/fixtures/lstm_step.onnx').readAsBytes(),
      );
      final ml = MlScheduler(cache: cache, currentTick: () => tick);
      addTearDown(ml.close);
      final charBrain = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: character.controller.actor,
          modelHash: model.sha256,
        ),
        contract: f.contract(model, ActionDecoder.character()),
        ml: ml,
        entities: character.simulation.session.entities,
      );
      final carBrain = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: vehicle.actor,
          modelHash: model.sha256,
        ),
        contract: f.contract(model, ActionDecoder.vehicle()),
        ml: ml,
        entities: vehicle.simulation.session.entities,
      );
      addTearDown(charBrain.close);
      addTearDown(carBrain.close);
      final nativeBefore = const MlRuntime().diagnostics.completedRuns;
      final charStart = character.body.state.pose.position;
      final carStart = vehicle.body.state.pose.position;
      for (var step = 0; step < sequence.length; step++) {
        final row = sequence[step] as Map;
        if (row['reset'] == true) {
          charBrain.reset(
            BrainReset(charBrain.identity, BrainResetReason.manual),
          );
          carBrain.reset(
            BrainReset(carBrain.identity, BrainResetReason.manual),
          );
        }
        f.sensor.values = (row['observation'] as List)
            .map((v) => (v as num).toDouble())
            .toList();
        final pending = <Future<BrainDecision?>>[];
        for (final brain in [charBrain, carBrain]) {
          brain.observe(f.frame(brain.identity, tick));
          pending.add(brain.request(f.context(brain, tick)));
        }
        await ml.flush();
        final candidates = await Future.wait(pending);
        expect(candidates, everyElement(isNotNull));
        // A native completion never changes memory before its due action applies.
        final versions = [charBrain.state.version, carBrain.state.version];
        character.step(2);
        vehicle.step(2);
        tick += 2;
        final expected = row['outputs'] as Map;
        for (var actor = 0; actor < 2; actor++) {
          final brain = [charBrain, carBrain][actor];
          final decision = brain.decide(f.context(brain, tick));
          expect(decision.isFallback, isFalse);
          expect(decision.applyTick, tick);
          expect(brain.state.version, versions[actor] + 1);
          near(decision.policyAction!.continuous, expected['action'] as List);
          near(
            brain.state.tensors['hidden']!.float32Values,
            expected['next_hidden'] as List,
          );
          near(
            brain.state.tensors['cell']!.float32Values,
            expected['next_cell'] as List,
          );
        }
        // Real adapters consume typed intents. Long trace comparison continues
        // without asserting probe task behavior or ground coverage.
        character.controller.apply(
          charBrain.decisions.currentAction.character!,
        );
        vehicle.controller.apply(carBrain.decisions.currentAction.vehicle!);
        character.step();
        vehicle.step();
        tick++;
      }
      expect(
        character.body.state.pose.position.distanceTo(charStart),
        greaterThan(.1),
      );
      expect(
        vehicle.body.state.pose.position.distanceTo(carStart),
        greaterThan(.1),
      );
      expect(cache.diagnostics.residentModels, 1);
      expect(
        (await cache.worker.diagnostics()).completedRuns,
        nativeBefore + 1000,
      );
      expect((await cache.worker.diagnostics()).liveResults, 0);
      for (final brain in [charBrain, carBrain]) {
        expect(brain.decisions.receipts.length, 256);
        expect(
          brain.decisions.receipts,
          everyElement(
            predicate<PolicyReceipt>(
              (r) => r.accepted && r.applyTick - r.observationTick == 2,
            ),
          ),
        );
      }
    },
  );

  test(
    'faulty native recurrent model brakes without committing hidden state',
    () async {
      final f = PolicyFixture();
      final actor = f.entities.spawn('actor');
      var tick = 1;
      final nativeBefore = const MlRuntime().diagnostics.completedRuns;
      final faulty = MlModelManifest.decode(
        File('test/fixtures/faulty_lstm.json').readAsStringSync(),
      );
      final ml = MlScheduler(
        cache: MlModelCache(
          resolver: (_) async =>
              File('test/fixtures/faulty_lstm.onnx').readAsBytes(),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
      final brain = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: actor,
          modelHash: faulty.sha256,
        ),
        contract: f.contract(faulty, ActionDecoder.vehicle()),
        ml: ml,
        entities: f.entities,
      );
      addTearDown(brain.close);
      brain.observe(f.frame(brain.identity, tick));
      final pending = brain.request(f.context(brain, tick));
      await ml.flush();
      expect(await pending, isNull);
      expect(brain.lastFailure!.status, MlOutcomeStatus.invalid);
      tick = 3;
      expect(brain.decide(f.context(brain, tick)).isFallback, isTrue);
      expect(brain.decisions.currentAction.vehicle!.brake, 1);
      expect(brain.state.version, 0);
      expect(brain.state.tensors['hidden']!.float32Values, everyElement(0));
      expect(
        (await ml.cache.worker.diagnostics()).completedRuns,
        nativeBefore + 1,
      );
      expect((await ml.cache.worker.diagnostics()).liveResults, 0);
    },
  );

  test(
    'real compacted actor batch preserves independent recurrent rows after cancellation',
    () async {
      final f = PolicyFixture();
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/lstm_step.json').readAsStringSync(),
      );
      var tick = 1;
      final worker = MlWorker();
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) async =>
              File('../zyren_ml/test/fixtures/lstm_step.onnx').readAsBytes(),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
      final brains = [
        for (final name in ['a', 'b', 'c'])
          PolicyBrain(
            identity: BrainIdentity(
              episodeId: 'ep',
              entity: f.entities.spawn(name),
              modelHash: model.sha256,
            ),
            contract: f.contract(model, ActionDecoder.character()),
            ml: ml,
            entities: f.entities,
          ),
      ];
      for (final brain in brains) {
        addTearDown(brain.close);
      }
      final outcomes = <Future<BrainDecision?>>[];
      for (var i = 0; i < 3; i++) {
        f.sensor.values = [i.toDouble(), .2, -.3, .4];
        brains[i].observe(f.frame(brains[i].identity, tick));
        outcomes.add(brains[i].request(f.context(brains[i], tick)));
      }
      final receipt = ml.batches.first;
      var dispatchedCancellation = false;
      final events = worker.events.listen((event) {
        if (event.operation == 'run') {
          dispatchedCancellation = true;
          brains[1].invalidatePending();
        }
      });
      addTearDown(events.cancel);
      await ml.flush();
      expect(dispatchedCancellation, isTrue);
      final candidates = await Future.wait(outcomes);
      expect(candidates[1], isNull);
      tick = 3;
      for (final brain in [brains[0], brains[2]]) {
        expect(brain.decide(f.context(brain, tick)).isFallback, isFalse);
        expect(brain.state.version, 1);
      }
      expect(brains[1].state.version, 0);
      expect(
        brains[0].state.tensors['hidden']!.float32Values,
        isNot(brains[2].state.tensors['hidden']!.float32Values),
      );
      final batch = await receipt;
      expect(batch.map.slotRequestIds.length, 2);
      expect(batch.map.nativeSlotIndices, [0, 2]);
      expect((await worker.diagnostics()).liveSessions, 1);
    },
  );
}
