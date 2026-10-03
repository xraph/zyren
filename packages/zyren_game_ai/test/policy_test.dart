import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_physics/zyren_physics.dart';
import '../../zyren_ml/test/support/delayed_worker.dart'
    show DelayedWorker, fakeManifest;

final class ProbeSensor implements GameSensor {
  List<double> values = [0, .2, -.3, .4];
  @override
  String get id => 'probe';
  @override
  int get cadenceTicks => 1;
  @override
  int get queryBudget => 0;
  @override
  ObservationSpec get schema => ObservationSpec(
    id: id,
    fields: [ObservationField('values', width: 4, min: -10, max: 10)],
  );
  @override
  SensorReading sample(SensorSnapshot snapshot, GameEntityHandle entity) =>
      SensorReading(
        sensorId: id,
        tick: snapshot.tick,
        state: SensorState.known,
        provenance: SensorProvenance.custom,
        values: values,
        validity: [1, 1, 1, 1],
      );
}

final class ProbeEncoder implements PolicyObservationEncoder {
  const ProbeEncoder();
  @override
  String get id => 'authored-probe-values-v1';
  @override
  MlTensor encode(ObservationFrame frame) =>
      MlTensor.float32([1, 4], frame.readings.single.values);
}

final class PolicyFixture {
  final entities = GameEntityTable();
  final sensor = ProbeSensor();
  late final ObservationAssembler assembler = ObservationAssembler(
    registry: SensorRegistry()..register(sensor),
    profile: SensorProfile(),
    latencyTicks: 2,
  );
  ObservationFrame frame(BrainIdentity id, int tick) => assembler.build(
    SensorSnapshot(
      episodeId: id.episodeId,
      tick: tick,
      worldRevision: 1,
      entities: [SensorEntity(handle: id.entity, pose: PhysicsPose())],
      colliders: {},
      currentRevision: () => 1,
      geometryLoaded: (_, _) => true,
    ),
    id.entity,
  );
  PolicyContract contract(MlModelManifest model, ActionDecoder decoder) =>
      PolicyContract(
        model: model,
        observation: assembler.spec,
        decoder: decoder,
        encoder: const ProbeEncoder(),
        latencyTicks: 2,
      );
  BrainContext context(
    PolicyBrain brain,
    int tick, {
    int gameEpoch = 0,
    int controlEpoch = 0,
  }) => BrainContext(
    identity: brain.identity,
    tick: tick,
    gameEpoch: gameEpoch,
    controlEpoch: controlEpoch,
    beliefs: [],
    goals: [],
    actionSpec: brain.contract.decoder.spec,
  );
}

void main() {
  test(
    'restoring100 to10 discards old pending work and accepts an earlier new frame',
    () async {
      final f = PolicyFixture(), model = fakeManifest();
      var tick = 100;
      final backend = DelayedWorker();
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: backend,
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
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
      addTearDown(brain.close);
      brain.observe(f.frame(brain.identity, tick));
      brain.decide(f.context(brain, tick));
      final old = brain.pending;
      final flushing = ml.flush();
      await backend.started.future;
      brain.synchronize(gameEpoch: 1, controlEpoch: 0, paused: false);
      tick = 10;
      brain.observe(f.frame(brain.identity, tick));
      expect(
        brain.decide(f.context(brain, tick, gameEpoch: 1)).isFallback,
        isTrue,
      );
      final newer = brain.pending;
      backend.finish();
      expect(await old, isNull);
      await backend.twoStarted.future;
      backend.finishAt(1);
      await flushing;
      expect(await newer, isNotNull);
      tick = 12;
      expect(
        brain.decide(f.context(brain, tick, gameEpoch: 1)).isFallback,
        isFalse,
      );
    },
  );

  test(
    'hybrid switching cancels a registered learned skill before scripted execution',
    () async {
      final f = PolicyFixture(), model = fakeManifest();
      final actor = f.entities.spawn('actor');
      final id = BrainIdentity(
        episodeId: 'ep',
        entity: actor,
        modelHash: model.sha256,
      );
      final backend = DelayedWorker();
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: backend,
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => 1,
      );
      addTearDown(ml.close);
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
        skills: {'learned': learned, 'idle': scripted},
        actionSpecs: {
          'learned': learned.contract.decoder.spec,
          'idle': ScriptedBrain.characterActions,
        },
      );
      addTearDown(hybrid.close);
      hybrid.observe(f.frame(id, 1));
      BrainContext ctx(int tick, String skill) => BrainContext(
        identity: id,
        tick: tick,
        beliefs: [],
        goals: [GameGoal(id: skill, skill: skill)],
        actionSpec: learned.contract.decoder.spec,
      );
      hybrid.decide(ctx(1, 'learned'));
      final pending = learned.pending;
      final flush = ml.flush();
      await backend.started.future;
      final result = hybrid.decide(ctx(2, 'idle'));
      expect(result.actions.single.action, 'ai.move');
      backend.finish();
      await flush;
      expect(await pending, isNull);
      expect(learned.state.version, 0);
      expect(hybrid.activeSkill, 'idle');
    },
  );

  test(
    'pause, restored epoch and ownership changes discard a pending worker result',
    () async {
      final fixture = PolicyFixture();
      final model = fakeManifest();
      var tick = 1;
      final backend = DelayedWorker();
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: backend,
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
        contract: fixture.contract(model, ActionDecoder.character()),
        ml: ml,
        entities: fixture.entities,
      );
      addTearDown(brain.close);
      brain.observe(fixture.frame(brain.identity, 1));
      final pending = brain.request(fixture.context(brain, 1));
      final flushing = ml.flush();
      await backend.started.future;
      brain.synchronize(gameEpoch: 1, controlEpoch: 1, paused: true);
      backend.finish();
      await flushing;
      expect(await pending, isNull);
      expect(brain.state.version, 0);
      tick = 3;
      expect(
        brain
            .decide(fixture.context(brain, 3, gameEpoch: 1, controlEpoch: 1))
            .isFallback,
        isTrue,
      );
      expect(brain.decisions.currentAction.character!.moveX, 0);
      brain.synchronize(gameEpoch: 2, controlEpoch: 2, paused: false);
      expect(brain.decisions.hasStaged, isFalse);
      // A restored game tick may move backward even when episode identity stays.
      brain.invalidatePending();
      tick = 1;
      brain.observe(fixture.frame(brain.identity, tick));
      expect(
        brain
            .decide(fixture.context(brain, tick, gameEpoch: 2, controlEpoch: 2))
            .isFallback,
        isTrue,
      );
    },
  );
}
