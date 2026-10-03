import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import '../../zyren_ml/test/support/delayed_worker.dart';
import 'policy_test.dart' show PolicyFixture;

void main() {
  test(
    'state snapshot rejects foreign, oversized and nonfinite storage atomically',
    () {
      final model = MlModelManifest.decode(
        File(
          'packages/zyren_ml/test/fixtures/lstm_step.json',
        ).readAsStringSync(),
      );
      final state = PolicyState(model);
      final snapshot = state.snapshot();
      final valid = jsonDecode(snapshot.encode()) as Map<String, dynamic>;
      state.restoreSnapshot(PolicyStateSnapshot.decode(jsonEncode(valid)));
      final before = state.snapshot().encode();
      for (final corrupt in [
        {...valid, 'modelHash': '0' * 64},
        {...valid, 'version': -1},
        {
          ...valid,
          'tensors': {
            'hidden': {
              'dtype': 'float32',
              'shape': [1, 1000000000],
              'bytes': '',
            },
          },
        },
      ]) {
        expect(
          () => state.restoreSnapshot(
            PolicyStateSnapshot.decode(jsonEncode(corrupt)),
          ),
          throwsA(anything),
        );
        expect(state.snapshot().encode(), before);
      }
      final tensors = Map<String, dynamic>.from(valid['tensors'] as Map);
      final hidden = Map<String, dynamic>.from(tensors['hidden'] as Map);
      final bytes = base64Decode(hidden['bytes'] as String);
      ByteData.sublistView(bytes).setFloat32(0, double.nan, Endian.little);
      hidden['bytes'] = base64Encode(bytes);
      tensors['hidden'] = hidden;
      expect(
        () => state.restoreSnapshot(
          PolicyStateSnapshot.decode(
            jsonEncode({...valid, 'tensors': tensors}),
          ),
        ),
        throwsA(anything),
      );
      expect(state.snapshot().encode(), before);
    },
  );

  test(
    'pause preserves committed state, restore remaps historical memory and seeds epochs',
    () async {
      final f = PolicyFixture();
      final model = MlModelManifest.decode(
        File(
          'packages/zyren_ml/test/fixtures/lstm_step.json',
        ).readAsStringSync(),
      );
      var tick = 10;
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: DelayedWorker(),
          resolver: (_) async => Uint8List(1),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
      final actor = f.entities.spawn('actor'),
          target = f.entities.spawn('target');
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
      final hidden = {
        for (final entry in brain.state.tensors.entries)
          entry.key: MlTensor.float32(
            entry.value.shape,
            List.filled(entry.value.byteLength ~/ 4, .25),
          ),
      };
      expect(
        brain.decisions.accept(
          BrainDecision.policy(
            identity: brain.identity,
            observationTick: 8,
            applyTick: tick,
            actionSchemaHash: brain.contract.decoder.spec.hash,
            action: PolicyAction([.2, .3], []),
            nextHiddenState: hidden,
            baseStateVersion: 0,
            stateEpoch: brain.state.epoch,
          ),
          tick: tick,
        ),
        isTrue,
      );
      brain.memory.observe(
        target: target,
        position: const Vec3(2, 0, 3),
        tick: 8,
      );
      brain.synchronize(
        gameEpoch: 1,
        controlEpoch: 1,
        paused: true,
        preserveCommittedState: true,
      );
      expect(brain.state.version, 1);
      final saved = PolicyBrainCheckpoint.decode(
        brain.snapshotCommitted(tick: tick).encode(),
      );
      f.entities.despawn(actor);
      f.entities.despawn(target);
      final freshActor = f.entities.spawn('actor'),
          freshTarget = f.entities.spawn('target');
      final fresh = BrainIdentity(
        episodeId: 'restored',
        entity: freshActor,
        modelHash: model.sha256,
      );
      brain.restoreCommitted(
        saved,
        identity: fresh,
        tick: tick,
        gameEpoch: 7,
        controlEpoch: 9,
        paused: true,
        remap: (h) => h == actor
            ? freshActor
            : h == target
            ? freshTarget
            : null,
      );
      expect(brain.state.version, 1);
      expect(brain.state.tensors['hidden']!.float32Values, everyElement(.25));
      final belief = brain.memory.atTick(tick).single;
      expect(belief.target, freshTarget);
      expect(belief.positionFrame, freshActor);
      expect(belief.ageTicks, 2);
      expect(belief.position, const Vec3(2, 0, 3));
      brain.synchronize(
        gameEpoch: 8,
        controlEpoch: 10,
        paused: false,
        preserveCommittedState: true,
      );
      expect(brain.state.version, 1);
      brain.observe(f.frame(fresh, tick));
      expect(
        brain
            .decide(f.context(brain, tick, gameEpoch: 8, controlEpoch: 10))
            .isFallback,
        isTrue,
      );
    },
  );

  test(
    'hybrid restores active learned slot without resetting child and scripted memory is remapped',
    () async {
      final f = PolicyFixture(), model = fakeManifest();
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: DelayedWorker(),
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => 10,
      );
      addTearDown(ml.close);
      final actor = f.entities.spawn('actor'),
          target = f.entities.spawn('target');
      final id = BrainIdentity(
        episodeId: 'ep',
        entity: actor,
        modelHash: model.sha256,
      );
      final learned = PolicyBrain(
        identity: id,
        contract: f.contract(model, ActionDecoder.character()),
        ml: ml,
        entities: f.entities,
      );
      final scripted = ScriptedBrain(identity: id, entities: f.entities);
      final hybrid = HybridBrain(
        identity: id,
        selector: UtilityGoalSelector(minCommitmentTicks: 0),
        skills: {'learned': learned, 'idle': _BaselineAdapter(scripted)},
        actionSpecs: {
          'learned': learned.contract.decoder.spec,
          'idle': scripted.actionSpec,
        },
      );
      addTearDown(hybrid.close);
      expect(
        learned.decisions.accept(
          BrainDecision.policy(
            identity: id,
            observationTick: 8,
            applyTick: 10,
            actionSchemaHash: learned.contract.decoder.spec.hash,
            action: PolicyAction([0, 0], []),
            nextHiddenState: {},
            baseStateVersion: 0,
            stateEpoch: learned.state.epoch,
          ),
          tick: 10,
        ),
        isTrue,
      );
      scripted.memory.observe(
        target: target,
        position: const Vec3(1, 0, 2),
        tick: 8,
      );
      final memory = scripted.snapshotCommitted(tick: 10);
      final state = learned.snapshotCommitted(tick: 10);
      f.entities.despawn(actor);
      f.entities.despawn(target);
      final freshActor = f.entities.spawn('actor'),
          freshTarget = f.entities.spawn('target');
      final freshId = BrainIdentity(
        episodeId: 'fresh',
        entity: freshActor,
        modelHash: model.sha256,
      );
      remap(h) => h == actor
          ? freshActor
          : h == target
          ? freshTarget
          : null;
      learned.restoreCommitted(
        state,
        identity: freshId,
        tick: 10,
        gameEpoch: 1,
        controlEpoch: 1,
        paused: true,
        remap: remap,
      );
      scripted.restoreCommitted(
        memory,
        identity: freshId,
        tick: 10,
        remap: remap,
      );
      hybrid.restoreActiveSkill(identity: freshId, activeSkill: 'learned');
      expect(scripted.memory.atTick(10).single.target, freshTarget);
      expect(
        () => hybrid.restoreActiveSkill(
          identity: freshId,
          activeSkill: 'missing',
        ),
        throwsStateError,
      );
      hybrid.decide(
        BrainContext(
          identity: freshId,
          tick: 10,
          gameEpoch: 1,
          controlEpoch: 1,
          beliefs: [],
          goals: [GameGoal(id: 'learned', skill: 'learned')],
          actionSpec: learned.contract.decoder.spec,
        ),
      );
      expect(learned.state.version, 1);
      expect(hybrid.activeSkill, 'learned');
      final corrupted = jsonDecode(state.encode()) as Map<String, dynamic>;
      (corrupted['memory'] as Map)['profileHash'] = '0' * 64;
      final before = learned.snapshotCommitted(tick: 10).encode();
      expect(
        () => learned.restoreCommitted(
          PolicyBrainCheckpoint.decode(jsonEncode(corrupted)),
          identity: freshId,
          tick: 10,
          gameEpoch: 3,
          controlEpoch: 3,
          paused: false,
          remap: (h) => h == actor
              ? freshActor
              : h == target
              ? freshTarget
              : null,
        ),
        throwsArgumentError,
      );
      expect(learned.snapshotCommitted(tick: 10).encode(), before);
    },
  );

  test(
    'quiescence waits invalidated actual work and checkpoint cannot omit it',
    () async {
      final f = PolicyFixture(),
          model = fakeManifest(),
          worker = DelayedWorker();
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => 1,
      );
      addTearDown(ml.close);
      final brain = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: f.entities.spawn('actor'),
          modelHash: model.sha256,
        ),
        contract: f.contract(model, ActionDecoder.character()),
        ml: ml,
        entities: f.entities,
      );
      addTearDown(brain.close);
      brain.observe(f.frame(brain.identity, 1));
      final request = brain.request(f.context(brain, 1));
      final flush = ml.flush();
      await worker.started.future;
      brain.synchronize(gameEpoch: 0, controlEpoch: 0, paused: true);
      expect(() => brain.snapshotCommitted(tick: 1), throwsStateError);
      var closed = false;
      final quiescence = brain.quiesce().then((_) => closed = true);
      await Future<void>.delayed(Duration.zero);
      expect(closed, isFalse);
      worker.finish();
      await flush;
      expect(await request, isNull);
      await quiescence;
      expect(brain.snapshotCommitted(tick: 1).state.version, 0);
    },
  );
}

final class _BaselineAdapter implements GameBrainCheckpointIdentity {
  final ScriptedBrain delegate;
  _BaselineAdapter(this.delegate);
  @override
  BrainIdentity get identity => delegate.identity;
  @override
  bool get checkpointQuiescent => true;
  @override
  void observe(ObservationFrame frame) => delegate.observe(frame);
  @override
  BrainDecision decide(BrainContext context) => delegate.decide(context);
  @override
  void reset(BrainReset reset) => delegate.reset(reset);
  @override
  Future<void> close() => delegate.close();
}
