import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game_ai/visual_v2.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'policy_test.dart' show PolicyFixture;
import '../../zyren_ml/test/support/delayed_worker.dart' show fakeManifest;

MlModelManifest model({
  int width = 4,
  int outputWidth = 2,
  int byte = 7,
  bool start = true,
  MlDtype startType = MlDtype.bool,
  List<int> hidden = const [1, -1, 128],
  List<int> maxHidden = const [1, 64, 128],
}) => MlModelManifest(
  id: 'record',
  modelFile: 'record$byte.onnx',
  sha256: fakeManifest(byte: byte).sha256,
  opset: 17,
  inputs: [
    MlTensorSpec(
      name: 'observation',
      dtype: MlDtype.float32,
      shape: [-1, width],
      maxShape: [64, width],
    ),
    if (start)
      MlTensorSpec(
        name: 'episode_start',
        dtype: startType,
        shape: [-1],
        maxShape: [64],
      ),
    for (final name in ['hidden_h', 'hidden_c'])
      MlTensorSpec(
        name: name,
        dtype: MlDtype.float32,
        shape: hidden,
        maxShape: maxHidden,
      ),
  ],
  outputs: [
    MlTensorSpec(
      name: outputWidth == 74 ? 'visual_estimate' : 'action',
      dtype: MlDtype.float32,
      shape: [-1, outputWidth],
      maxShape: [64, outputWidth],
    ),
    for (final name in ['next_hidden_h', 'next_hidden_c'])
      MlTensorSpec(
        name: name,
        dtype: MlDtype.float32,
        shape: hidden,
        maxShape: maxHidden,
      ),
  ],
  recurrent: {'hidden_h': 'next_hidden_h', 'hidden_c': 'next_hidden_c'},
);

final class RecordWorker implements MlInferenceWorker {
  final List<MlTensorMap> calls = [];
  List<double> output = [.2, .3];
  bool leakBatch = false;
  @override
  Future<Duration> load(MlModelManifest model, Uint8List bytes) async =>
      Duration.zero;
  @override
  Future<MlRunResult> run(
    String hash,
    MlTensorMap tensors,
    MlRunOptions options,
  ) async {
    calls.add(tensors);
    return MlRunResult(
      MlRunStatus.ok,
      tensors: {
        output.length == 74 ? 'visual_estimate' : 'action': MlTensor.float32([
          1,
          output.length,
        ], output),
        for (final name in ['next_hidden_h', 'next_hidden_c'])
          name: MlTensor.float32(
            leakBatch
                ? [1, 2, 128]
                : tensors[name == 'next_hidden_h' ? 'hidden_h' : 'hidden_c']!
                      .shape,
            List.filled(leakBatch ? 256 : 128, .5),
          ),
      },
      elapsed: Duration.zero,
    );
  }

  @override
  Future<void> release(String hash) async {}
  @override
  Future<void> close() async {}
  @override
  Future<MlWorkerDiagnostics> diagnostics() async => const MlWorkerDiagnostics(
    residentModels: 0,
    liveSessions: 0,
    liveResults: 0,
  );
}

void main() {
  test(
    'all six captured profiles preserve availability, depth masks and float32 ownership',
    () {
      final actor = GameEntityTable().spawn('actor');
      for (final family in ['guard', 'vehicle']) {
        for (final mode in ['rgb', 'depth', 'combined']) {
          final profile = VisualNavigationProfile(family: family, mode: mode);
          final body = List<double>.from(
            profile.ownBody(
              pose: PhysicsPose(),
              velocity: const Vec3(.123456789, 0, 0),
              angularVelocity: const Vec3(0, 0, 0),
              cameraYaw: .17,
            ),
          );
          final pixels = Float32List(profile.camera.channels * 84 * 84);
          if (profile.camera.depth) {
            pixels.fillRange(84 * 84 * 4, pixels.length, 1);
          }
          final captured = MlTensor.float32([
            1,
            profile.camera.channels,
            84,
            84,
          ], pixels);
          final frame = profile.frame(
            episodeId: 'ep',
            entity: actor,
            tick: 5,
            worldRevision: 7,
            captured: captured,
            ownBody: body,
          );
          final encoded = VisualNavigationPolicyEncoder(profile).encode(frame);
          expect(encoded.shape, [1, profile.width]);
          body[0] = 99;
          expect(frame.readings[1].values[0], closeTo(.123456789, 1e-7));
          final unknown = profile.frame(
            episodeId: 'ep',
            entity: actor,
            tick: 5,
            worldRevision: 7,
          );
          expect(unknown.readings[0].state, SensorState.unknown);
          expect(unknown.readings[0].validity, everyElement(0));
          expect(
            () => VisualNavigationPolicyEncoder(profile).encode(unknown),
            throwsStateError,
          );
          final noBody = profile.frame(
            episodeId: 'ep',
            entity: actor,
            tick: 5,
            worldRevision: 7,
            captured: captured,
          );
          expect(
            () => VisualNavigationPolicyEncoder(profile).encode(noBody),
            throwsStateError,
          );
          expect(
            () => profile.frame(
              episodeId: 'ep',
              entity: actor,
              tick: 5,
              worldRevision: 7,
              captured: captured,
              cameraState: SensorState.unavailable,
            ),
            throwsArgumentError,
          );
          final changed = [
            frame.readings[0],
            SensorReading(
              sensorId: 'own-body',
              tick: 5,
              state: SensorState.known,
              provenance: SensorProvenance.custom,
              values: frame.readings[1].values,
              validity: List.filled(10, 1),
              configurationHash: profile.hash,
            ),
          ];
          expect(
            () => ObservationFrame.capturedReadings(
              spec: profile.spec,
              configurationHash: profile.hash,
              episodeId: 'ep',
              entity: actor,
              tick: 5,
              worldRevision: 7,
              readings: changed,
            ),
            throwsArgumentError,
          );
        }
      }
    },
  );

  test(
    'record decoder keeps estimates separate from motor intents and rejects optical impossibility',
    () {
      final profile = VisualNavigationProfile(
        family: 'guard',
        mode: 'combined',
      );
      final contract = visualNavigationPolicyContract(
        profile: profile,
        model: model(width: profile.width, outputWidth: 74),
      );
      final decoded = contract.decoder.fallback;
      expect(decoded.action.continuous, hasLength(74));
      expect(decoded.character, isNull);
      expect(decoded.vehicle, isNull);
      final bad = List<double>.from(VisualEstimate.spec.fallbackContinuous)
        ..[0] = 40
        ..[1] = 1
        ..[4] = .1
        ..[6] = 1
        ..[7] = 1;
      expect(
        contract.decodeOutputs({
          'visual_estimate': MlTensor.float32([1, 74], bad),
        }),
        isNull,
      );
      expect(
        () => ActionDecoder.validatedRecord(
          spec: VisualEstimate.spec,
          validate: (_) => false,
        ),
        throwsArgumentError,
      );
      final throwing = ActionDecoder.validatedRecord(
        spec: VisualEstimate.spec,
        validate: (a) {
          if (a.continuous[0] != 0) throw StateError('invalid record');
          return true;
        },
      );
      expect(throwing.decode(PolicyAction(bad, [])), isNull);
    },
  );
  test(
    'episode-start binding is explicit and old serialized contract remains unchanged',
    () {
      final f = PolicyFixture();
      final legacy = f.contract(fakeManifest(), ActionDecoder.character());
      expect(legacy.toJson().containsKey('episodeStartInput'), isFalse);
      expect(
        () => PolicyContract(
          model: model(),
          observation: f.assembler.spec,
          decoder: ActionDecoder.character(),
          encoder: legacy.encoder,
          latencyTicks: 2,
        ),
        throwsArgumentError,
      );
      expect(
        () => PolicyContract(
          model: model(startType: MlDtype.float32),
          observation: f.assembler.spec,
          decoder: ActionDecoder.character(),
          encoder: legacy.encoder,
          latencyTicks: 2,
          episodeStartInput: 'episode_start',
        ),
        throwsArgumentError,
      );
      final bound = PolicyContract(
        model: model(),
        observation: f.assembler.spec,
        decoder: ActionDecoder.character(),
        encoder: legacy.encoder,
        latencyTicks: 2,
        episodeStartInput: 'episode_start',
      );
      expect(bound.toJson()['episodeStartInput'], 'episode_start');
    },
  );
  test(
    'rank-three state admits one actor batch and refuses unsupported dynamic axes',
    () {
      final state = PolicyState(model());
      expect(state.tensors['hidden_h']!.shape, [1, 1, 128]);
      expect(state.byteLength, 1024);
      expect(
        state.accepts({
          for (final name in ['hidden_h', 'hidden_c'])
            name: MlTensor.float32([1, 2, 128], List.filled(256, 0)),
        }),
        isFalse,
      );
      expect(
        () =>
            PolicyState(model(hidden: [-1, -1, 128], maxHidden: [64, 64, 128])),
        throwsArgumentError,
      );
      expect(() => PolicyState(model(), maxBytes: 512), throwsArgumentError);
      final legacy = PolicyState(
        model(hidden: [-1, 128], maxHidden: [64, 128], start: false),
      );
      expect(legacy.tensors['hidden_h']!.shape, [1, 128]);
    },
  );
  test(
    'two actors keep private rank-three state and episode-start tracks committed reset',
    () async {
      final f = PolicyFixture(), manifest = model(), worker = RecordWorker();
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
      final contract = PolicyContract(
        model: manifest,
        observation: f.assembler.spec,
        decoder: ActionDecoder.character(),
        encoder: f.contract(fakeManifest(), ActionDecoder.character()).encoder,
        latencyTicks: 2,
        episodeStartInput: 'episode_start',
      );
      PolicyBrain brain(String name) => PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: f.entities.spawn(name),
          modelHash: manifest.sha256,
        ),
        contract: contract,
        ml: ml,
        entities: f.entities,
        autoRequest: false,
      );
      final a = brain('a'), b = brain('b');
      addTearDown(a.close);
      addTearDown(b.close);
      final requests = <Future<BrainDecision?>>[];
      for (final actor in [a, b]) {
        actor.observe(f.frame(actor.identity, tick));
        requests.add(actor.request(f.context(actor, tick)));
      }
      await ml.flush();
      await Future.wait(requests);
      expect(worker.calls, hasLength(2));
      for (final call in worker.calls) {
        expect(call['episode_start']!.boolValues, [true]);
        expect(call['hidden_h']!.shape, [1, 1, 128]);
        expect(call['observation']!.shape, [1, 4]);
      }
      expect(a.state.version, 0);
      expect(b.state.version, 0);
      tick = 3;
      a.decide(f.context(a, tick));
      b.decide(f.context(b, tick));
      expect(a.state.version, 1);
      expect(b.state.version, 1);
      tick = 4;
      a.observe(f.frame(a.identity, tick));
      final next = a.request(f.context(a, tick));
      await ml.flush();
      await next;
      expect(worker.calls.last['episode_start']!.boolValues, [false]);
      expect(worker.calls.last['hidden_h']!.float32Values.first, .5);
      a.invalidatePending();
      a.state.reset();
      tick = 5;
      a.observe(f.frame(a.identity, tick));
      final reset = a.request(f.context(a, tick));
      await ml.flush();
      await reset;
      expect(worker.calls.last['episode_start']!.boolValues, [true]);
      expect(worker.calls.last['hidden_h']!.float32Values.first, 0);
    },
  );
  test(
    'mixed legacy and rank-three models are never stacked into another actor batch',
    () async {
      final f = PolicyFixture(), worker = RecordWorker();
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (m) async =>
              Uint8List.fromList([m == 'record7.onnx' ? 7 : 8]),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
      final modern = model(),
          legacy = model(
            byte: 8,
            start: false,
            hidden: [-1, 128],
            maxHidden: [64, 128],
          );
      final actors = <PolicyBrain>[];
      final requests = <Future<BrainDecision?>>[];
      for (final manifest in [modern, legacy]) {
        final actor = PolicyBrain(
          identity: BrainIdentity(
            episodeId: 'ep',
            entity: f.entities.spawn('actor${actors.length}'),
            modelHash: manifest.sha256,
          ),
          contract: PolicyContract(
            model: manifest,
            observation: f.assembler.spec,
            decoder: ActionDecoder.character(),
            encoder: f
                .contract(fakeManifest(), ActionDecoder.character())
                .encoder,
            latencyTicks: 2,
            episodeStartInput: manifest == modern ? 'episode_start' : null,
          ),
          ml: ml,
          entities: f.entities,
          autoRequest: false,
        );
        actors.add(actor);
        addTearDown(actor.close);
        actor.observe(f.frame(actor.identity, tick));
        requests.add(actor.request(f.context(actor, tick)));
      }
      await ml.flush();
      expect(await Future.wait(requests), everyElement(isNotNull));
      expect(worker.calls, hasLength(2));
      expect(
        worker.calls.map((c) => c['observation']!.shape.first),
        everyElement(1),
      );
      expect(worker.calls.map((c) => c['hidden_h']!.shape.length).toSet(), {
        2,
        3,
      });
      expect(
        worker.calls.where((c) => c.containsKey('episode_start')),
        hasLength(1),
      );
      tick = 3;
      for (final actor in actors) {
        actor.decide(f.context(actor, tick));
        expect(actor.state.version, 1);
      }
    },
  );
  test(
    'invalid estimate or leaked hidden batch never commits either output',
    () async {
      final profile = VisualNavigationProfile(
        family: 'guard',
        mode: 'combined',
      );
      final f = PolicyFixture(),
          worker = RecordWorker(),
          manifest = model(outputWidth: 74);
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          worker: worker,
          resolver: (_) async => Uint8List.fromList([7]),
        ),
        currentTick: () => tick,
      );
      addTearDown(ml.close);
      final domain = visualNavigationPolicyContract(
        profile: profile,
        model: model(width: profile.width, outputWidth: 74),
      ).decoder;
      final contract = PolicyContract(
        model: manifest,
        observation: f.assembler.spec,
        decoder: domain,
        encoder: f.contract(fakeManifest(), ActionDecoder.character()).encoder,
        continuousOutput: 'visual_estimate',
        latencyTicks: 2,
        episodeStartInput: 'episode_start',
      );
      final actor = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: f.entities.spawn('actor'),
          modelHash: manifest.sha256,
        ),
        contract: contract,
        ml: ml,
        entities: f.entities,
        autoRequest: false,
      );
      addTearDown(actor.close);
      worker.output = List<double>.from(VisualEstimate.spec.fallbackContinuous)
        ..[0] = 40
        ..[1] = 1
        ..[6] = 1
        ..[7] = 1;
      actor.observe(f.frame(actor.identity, tick));
      final bad = actor.request(f.context(actor, tick));
      await ml.flush();
      expect(await bad, isNull);
      tick = 3;
      actor.decide(f.context(actor, tick));
      expect(actor.state.version, 0);
      worker.output = VisualEstimate.spec.fallbackContinuous;
      worker.leakBatch = true;
      tick = 4;
      actor.observe(f.frame(actor.identity, tick));
      final leaked = actor.request(f.context(actor, tick));
      await ml.flush();
      expect(await leaked, isNull);
      tick = 6;
      actor.decide(f.context(actor, tick));
      expect(actor.state.version, 0);
      expect(actor.state.tensors['hidden_h']!.float32Values.first, 0);
    },
  );
}
