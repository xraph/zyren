import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_capture/sensors.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import '../../zyren_game_native/test/support/character_fixture.dart';
import '../../zyren_native/test/support/deformation_checks.dart' show skinBox;

final native = Platform.environment['RUN_NATIVE_GPU'] == '1';

final class _StartedBackend implements RenderBackend {
  final RenderBackend backend;
  final started = Completer<void>();
  int completed = 0;
  _StartedBackend(this.backend);
  @override
  DeviceCapabilities get capabilities => backend.capabilities;
  @override
  Future<FrameOutput> render(FrameSubmission frame) async {
    final result = backend.render(frame);
    if (!started.isCompleted) started.complete();
    final output = await result;
    completed++;
    return output;
  }

  @override
  Future<void> close() => backend.close();
}

void main() {
  SensorCaptureRequest request(
    Scene scene,
    int tick, {
    int width = 84,
    int height = 84,
    DepthStrategy strategy = DepthStrategy.standard,
    double near = .1,
    double far = 100,
  }) => SensorCaptureRequest(
    id: 'r$tick',
    tick: tick,
    scene: scene,
    depth: true,
    size: PhysicalSize(width, height),
    camera: PerspectiveCamera(
      position: const Vec3(0, 0, 5),
      target: Vec3.zero,
      depthStrategy: strategy,
      near: near,
      far: far,
    ),
  );
  Scene fixture() => Scene()
    ..add(
      Mesh(
        PlaneGeometry(width: 2, height: 2),
        UnlitMaterial(color: const Color3(1, 0, 0)),
      ),
    );

  test(
    'native RGB and metric depth pin plane, clear, reverse Z and MSAA',
    () async {
      final backend = await NativeBackend.create();
      final pool = SensorCapturePool(openBackend: () async => backend);
      addTearDown(pool.close);
      expect(
        backend.capabilities.supports(RenderFeature.classMaskReadback),
        false,
      );
      final scene = fixture();
      var tick = 0;
      for (final strategy in DepthStrategy.values) {
        for (final sampleCount in [1, 4]) {
          scene.renderSettings = RenderSettings(sampleCount: sampleCount);
          final receipt = await pool.capture(
            request(
              scene,
              ++tick,
              strategy: strategy,
              near: strategy == DepthStrategy.reversed ? .001 : .1,
              far: strategy == DepthStrategy.reversed ? 10000 : 100,
            ),
          );
          expect(receipt.tick, tick);
          expect(receipt.width, 84);
          expect(receipt.height, 84);
          expect(receipt.depth!.validAt(42, 42), true);
          expect(receipt.depth!.metresAt(42, 42), closeTo(5, .01));
          expect(receipt.depth!.validAt(0, 0), false);
          expect(receipt.depth!.metresAt(0, 0), isNull);
          final pixel = (42 * 84 + 42) * 4;
          expect(receipt.image.pixels[pixel], greaterThan(200));
          expect(receipt.image.pixels[pixel + 1], lessThan(10));
          expect(receipt.stats.profile!.cpuReadbackNs, greaterThan(0));
        }
      }
      print(
        'A6_FEASIBILITY ${jsonEncode({'backend': backend.capabilities.backend, 'adapter': backend.capabilities.adapterName, 'rgb': true, 'metricDepth': true, 'reverseZ': true, 'msaa4': true, 'classMask': false})}',
      );
    },
    skip: !native,
  );

  test(
    'hidden colored movement leaves native pixels and metric depth invariant',
    () async {
      final pool = SensorCapturePool(openBackend: NativeBackend.create);
      addTearDown(pool.close);
      final scene = fixture();
      final hidden = scene.add(
        Mesh(
          BoxGeometry(width: .4, height: .4, depth: .4),
          UnlitMaterial(color: const Color3(0, 1, 0)),
        )..position = const Vec3(0, 0, -1),
      );
      final before = await pool.capture(request(scene, 1));
      hidden.position = const Vec3(.3, .2, -2);
      final after = await pool.capture(request(scene, 2));
      expect(after.image.pixels, orderedEquals(before.image.pixels));
      expect(after.depth!.metres, orderedEquals(before.depth!.metres));
      hidden.position = const Vec3(0, 0, 1);
      final visible = await pool.capture(request(scene, 3));
      expect(visible.depth!.metresAt(42, 42), closeTo(3.8, .01));
      expect(visible.image.pixels[(42 * 84 + 42) * 4 + 1], 255);
    },
    skip: !native,
  );

  test(
    'native skin depth follows deformation, resize and recreation retain old buffers',
    () async {
      var opens = 0;
      final pool = SensorCapturePool(
        openBackend: () {
          opens++;
          return NativeBackend.create();
        },
      );
      addTearDown(pool.close);
      final scene = Scene();
      final hip = scene.add(Bone()), tip = hip.add(Bone());
      scene.add(
        SkinnedMesh(
          skinBox(),
          UnlitMaterial(color: const Color3(0, 0, 1)),
          skin: Skin.fromBindPose(
            joints: [hip, tip],
            meshBindMatrix: Mat4.identity(),
          ),
        ),
      );
      final first = await pool.capture(request(scene, 1));
      hip.position = const Vec3(0, 0, 1);
      final deformed = await pool.capture(
        request(scene, 2, width: 63, height: 47),
      );
      expect(first.depth!.metresAt(42, 42), closeTo(4.8, .01));
      expect(deformed.depth!.metresAt(31, 23), closeTo(3.8, .01));
      await pool.recreate();
      final recreated = await pool.capture(request(scene, 3));
      expect(recreated.resourceGeneration, first.resourceGeneration + 1);
      expect(recreated.depth!.metresAt(42, 42), closeTo(3.8, .01));
      expect(first.depth!.metresAt(42, 42), closeTo(4.8, .01));
      expect(opens, 2);
      await pool.close();
      await pool.close();
    },
    skip: !native,
  );

  test(
    'native cancellation waits for genuine submitted render before close',
    () async {
      final backend = _StartedBackend(await NativeBackend.create());
      final pool = SensorCapturePool(
        openBackend: () async => backend,
        maxPending: 1,
      );
      final pending = pool.capture(request(fixture(), 1));
      pending.ignore();
      await backend.started.future;
      pool.cancel('r1');
      expect(pool.pendingCount, 1);
      final closing = pool.close();
      await expectLater(pending, throwsA(isA<SensorCaptureCancelled>()));
      await closing;
      expect(backend.completed, 1);
      expect(pool.pendingCount, 0);
    },
    skip: !native,
  );

  test(
    'moving observer native captures execute actual CNN with correlated request pins',
    () async {
      final entities = GameEntityTable();
      final entity = entities.spawn('observer');
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/cnn_step.json').readAsStringSync(),
      );
      var tick = 1;
      final ml = MlScheduler(
        cache: MlModelCache(
          resolver: (_) =>
              File('../zyren_ml/test/fixtures/cnn_step.onnx').readAsBytes(),
        ),
        currentTick: () => tick,
      );
      final sensor = CameraSensor(
        CameraProfile(),
        openBackend: NativeBackend.create,
      );
      addTearDown(sensor.close);
      addTearDown(ml.close);
      final scene = fixture();
      final measurements = <Map<String, Object?>>[];
      final outputs = <List<double>>[];
      for (; tick <= 3; tick++) {
        final total = Stopwatch()..start();
        final snapshot = SensorSnapshot(
          episodeId: 'camera-episode',
          tick: tick,
          worldRevision: tick,
          entities: [
            SensorEntity(
              handle: entity,
              pose: PhysicsPose(position: Vec3((tick - 1) * .5, 0, 5)),
            ),
          ],
          colliders: {},
          currentRevision: () => tick,
          geometryLoaded: (_, _) => true,
        );
        final observation = await sensor.capture(
          snapshot: snapshot,
          entity: entity,
          scene: scene,
        );
        expect(sensor.sample(snapshot, entity).state, SensorState.known);
        final result = ml.submit(
          MlRequest(
            id: 'cnn$tick',
            model: model,
            modelHash: model.sha256,
            tensors: {'image': observation.tensor},
            actorToken: entity,
            observationTick: tick,
            applicationTick: tick + 1,
            deadlineTick: tick + 1,
          ),
        );
        await ml.flush();
        final outcome = await result;
        expect(outcome.status, MlOutcomeStatus.ok);
        expect(outcome.observationTick, observation.receipt.tick);
        expect(outcome.actorToken, entity);
        expect(outcome.modelHash, model.sha256);
        outputs.add(outcome.tensors['action']!.float32Values);
        final later = SensorSnapshot(
          episodeId: 'camera-episode',
          tick: tick + 1,
          worldRevision: tick,
          entities: snapshot.entities.values,
          colliders: {},
          currentRevision: () => tick,
          geometryLoaded: (_, _) => true,
        );
        expect(sensor.sample(later, entity).state, SensorState.unknown);
        measurements.add({
          'tick': tick,
          'captureMicros': observation.receipt.elapsed.inMicroseconds,
          'gpuMicros': observation.receipt.stats.gpuTime?.inMicroseconds,
          'nativeMapAndPackNs':
              observation.receipt.stats.profile?.cpuReadbackNs,
          'preprocessMicros': observation.preprocessingTime.inMicroseconds,
          'inferenceMicros': outcome.timing.nativeRun.inMicroseconds,
          'mlWorkerRoundTripMicros':
              outcome.timing.workerRoundTrip.inMicroseconds,
          'totalMicros': total.elapsed.inMicroseconds,
        });
      }
      expect(outputs[0], isNot(orderedEquals(outputs[2])));
      print('A6_CNN_LATENCY ${jsonEncode(measurements)}');
    },
    skip: !native,
  );
  test(
    'actual camera CNN policy commits only at due tick and drives native character',
    () async {
      final character = await GameCharacterFixture.create(
        position: const Vec3(0, .81, 5),
      );
      addTearDown(character.close);
      final model = MlModelManifest.decode(
        File('../zyren_ml/test/fixtures/cnn_step.json').readAsStringSync(),
      );
      var tick = character.simulation.session.tick;
      final ml = MlScheduler(
        cache: MlModelCache(
          resolver: (_) =>
              File('../zyren_ml/test/fixtures/cnn_step.onnx').readAsBytes(),
        ),
        currentTick: () => tick,
      );
      final sensor = CameraSensor(
        CameraProfile(),
        openBackend: NativeBackend.create,
      );
      addTearDown(ml.close);
      addTearDown(sensor.close);
      final assembler = ObservationAssembler(
        registry: SensorRegistry()..register(sensor),
        profile: SensorProfile(),
      );
      final contract = PolicyContract(
        model: model,
        observation: assembler.spec,
        decoder: ActionDecoder.character(),
        observationInput: 'image',
        encoder: CameraPolicyEncoder(sensor.profile),
      );
      final entity = character.controller.actor;
      final brain = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'visual',
          entity: entity,
          modelHash: model.sha256,
        ),
        contract: contract,
        ml: ml,
        entities: character.simulation.session.entities,
      );
      addTearDown(brain.close);
      final snapshot = SensorSnapshot(
        episodeId: 'visual',
        tick: tick,
        worldRevision: tick,
        entities: [
          SensorEntity(handle: entity, pose: character.body.state.pose),
        ],
        colliders: {},
        currentRevision: () => tick,
        geometryLoaded: (_, _) => true,
      );
      final scene = fixture();
      scene.children.single.position = const Vec3(0, .81, 0);
      final observation = await sensor.capture(
        snapshot: snapshot,
        entity: entity,
        scene: scene,
      );
      brain.observe(assembler.build(snapshot, entity));
      BrainContext context() => BrainContext(
        identity: brain.identity,
        tick: tick,
        actionSpec: contract.decoder.spec,
        beliefs: [],
        goals: [],
      );
      final pending = brain.request(context());
      await ml.flush();
      final candidate = await pending;
      expect(candidate, isNotNull);
      expect(brain.state.version, 0);
      expect(candidate!.observationTick, observation.receipt.tick);
      final motorsBefore = character.motorSteps;
      character.step();
      tick = character.simulation.session.tick;
      final decision = brain.decide(context());
      expect(decision.isFallback, false);
      expect(decision.applyTick, tick);
      expect(brain.state.version, 1);
      final action = brain.decisions.currentAction.character!;
      character.controller.apply(action);
      character.step();
      expect(character.controller.lastIntent.moveX, action.moveX);
      expect(character.controller.lastIntent.moveZ, action.moveZ);
      expect(character.motorSteps, motorsBefore + 2);
    },
    skip: !native,
  );
}
