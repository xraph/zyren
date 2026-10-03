import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_ml/zyren_ml.dart';
import 'package:zyren_physics/zyren_physics.dart';
import '../../zyren_capture/test/capture_test.dart' show FixtureBackend;
import 'package:test/test.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  test(
    'RGB normalization pins channel order, stride, alpha and depth mask',
    () {
      final p = CameraProfile(
        width: 2,
        height: 1,
        depth: true,
        mean: [.1, .2, .3],
        std: [.5, 1, 2],
        maxMetres: 10,
      );
      final data = p.preprocess(
        ImageData(
          size: PhysicalSize(2, 1),
          pixels: Uint8List.fromList([255, 0, 128, 255, 0, 255, 0, 255]),
        ),
        DepthData(
          size: PhysicalSize(2, 1),
          metres: Float32List.fromList([5, 0]),
          validity: Uint8List.fromList([1, 0]),
        ),
      );
      expect(data.shape, [1, 5, 1, 2]);
      expect(data.float32Values[0], closeTo(1.8, 1e-6));
      expect(data.float32Values[2], closeTo(-.2, 1e-6));
      expect(data.float32Values.sublist(6), [.5, 0, 1, 0]);
      expect(p.toJson()['layout'], 'NCHW');
      expect(p.hash, isNot(CameraProfile(width: 2, height: 1).hash));
      expect(() => p.mean[0] = 3, throwsUnsupportedError);
      expect(() => CameraProfile(std: [0, 1, 1]), throwsArgumentError);
    },
  );
  test(
    '84 pixel camera schema admits actual CNN data with a bounded width',
    () {
      final profile = CameraProfile(depth: true);
      final sensor = CameraSensor(
        profile,
        openBackend: () => throw StateError('not opened'),
      );
      expect(sensor.schema.width, 84 * 84 * 5);
      expect(() => CameraProfile(width: 4096), throwsArgumentError);
    },
  );
  test(
    'native-style byte endpoints survive float32 schema validation and late ticks stay unknown',
    () async {
      final entities = GameEntityTable(),
          entity = GameEntityTable().spawn('observer');
      final sensor = CameraSensor(
        CameraProfile(
          width: 2,
          height: 1,
          mean: [.1, .2, .3],
          std: [.5, .3, .7],
        ),
        openBackend: () async => FixtureBackend(),
      );
      addTearDown(sensor.close);
      SensorSnapshot snapshot(int tick, {String episode = 'ep'}) =>
          SensorSnapshot(
            episodeId: episode,
            tick: tick,
            worldRevision: 0,
            entities: [SensorEntity(handle: entity, pose: PhysicsPose())],
            colliders: {},
            currentRevision: () => 0,
            geometryLoaded: (_, _) => true,
          );
      final registry = SensorRegistry()..register(sensor);
      final current = snapshot(1);
      expect(
        registry.sample(sensor, current, entity).state,
        SensorState.unknown,
      );
      await sensor.capture(snapshot: current, entity: entity, scene: Scene());
      expect(registry.sample(sensor, current, entity).state, SensorState.known);
      expect(
        registry.sample(sensor, snapshot(2), entity).state,
        SensorState.unknown,
      );
      expect(
        registry.sample(sensor, snapshot(1, episode: 'other'), entity).state,
        SensorState.unknown,
      );
      final replacement = entities.spawn('replacement');
      expect(
        registry.sample(sensor, current, replacement).state,
        SensorState.unknown,
      );
      sensor.invalidate();
      expect(
        registry.sample(sensor, current, entity).state,
        SensorState.unknown,
      );
    },
  );
  test(
    'camera policy rank4 contract rejects unknown pixels without a native request',
    () async {
      final entities = GameEntityTable();
      final sensor = CameraSensor(
        CameraProfile(width: 2, height: 1),
        openBackend: () async => FixtureBackend(),
      );
      final assembler = ObservationAssembler(
        registry: SensorRegistry()..register(sensor),
        profile: SensorProfile(),
      );
      final model = MlModelManifest(
        id: 'camera',
        modelFile: 'camera.onnx',
        sha256: '0' * 64,
        opset: 17,
        inputs: [
          MlTensorSpec(
            name: 'image',
            dtype: MlDtype.float32,
            shape: [-1, 3, 1, 2],
            maxShape: [1, 3, 1, 2],
          ),
        ],
        outputs: [
          MlTensorSpec(
            name: 'action',
            dtype: MlDtype.float32,
            shape: [-1, 2],
            maxShape: [1, 2],
          ),
        ],
      );
      final ml = MlScheduler(
        cache: MlModelCache(resolver: (_) async => Uint8List(0)),
        currentTick: () => 1,
      );
      final actual = entities.spawn('observer');
      final contract = PolicyContract(
        model: model,
        observation: assembler.spec,
        decoder: ActionDecoder.character(),
        encoder: CameraPolicyEncoder(sensor.profile),
        observationInput: 'image',
      );
      final brain = PolicyBrain(
        identity: BrainIdentity(
          episodeId: 'ep',
          entity: actual,
          modelHash: model.sha256,
        ),
        contract: contract,
        ml: ml,
        entities: entities,
      );
      addTearDown(brain.close);
      addTearDown(ml.close);
      addTearDown(sensor.close);
      final snapshot = SensorSnapshot(
        episodeId: 'ep',
        tick: 1,
        worldRevision: 0,
        entities: [SensorEntity(handle: actual, pose: PhysicsPose())],
        colliders: {},
        currentRevision: () => 0,
        geometryLoaded: (_, _) => true,
      );
      brain.observe(assembler.build(snapshot, actual));
      final context = BrainContext(
        identity: brain.identity,
        tick: 1,
        actionSpec: contract.decoder.spec,
        beliefs: [],
        goals: [],
      );
      expect(brain.decide(context).isFallback, true);
      expect(brain.lastFailure!.status, MlOutcomeStatus.invalid);
      expect(brain.hasPending, false);
      await sensor.capture(snapshot: snapshot, entity: actual, scene: Scene());
      final frame = assembler.build(snapshot, actual);
      expect(CameraPolicyEncoder(sensor.profile).encode(frame).shape, [
        1,
        3,
        1,
        2,
      ]);
      expect(
        () => CameraPolicyEncoder(
          CameraProfile(width: 2, height: 1, mean: [.1, 0, 0]),
        ).encode(frame),
        throwsStateError,
      );
    },
  );
  test(
    'camera profile pins controller-compatible forward and rejects parallel up',
    () async {
      final entities = GameEntityTable();
      final entity = entities.spawn('observer');
      final sensor = CameraSensor(
        CameraProfile(width: 2, height: 1),
        openBackend: () async => FixtureBackend(),
      );
      addTearDown(sensor.close);
      final snapshot = SensorSnapshot(
        episodeId: 'direction',
        tick: 1,
        worldRevision: 0,
        entities: [SensorEntity(handle: entity, pose: PhysicsPose())],
        colliders: {},
        currentRevision: () => 0,
        geometryLoaded: (_, _) => true,
      );
      final captured = await sensor.capture(
        snapshot: snapshot,
        entity: entity,
        scene: Scene(),
      );
      expect(captured.receipt.camera.forward, [0, 0, 1]);
      expect(sensor.profile.toJson()['forward'], [0, 0, 1]);
      final sideProfile = CameraProfile(
        width: 2,
        height: 1,
        forward: const Vec3(1, 0, 0),
      );
      expect(sideProfile.hash, isNot(sensor.profile.hash));
      final side = CameraSensor(
        sideProfile,
        openBackend: () async => FixtureBackend(),
      );
      addTearDown(side.close);
      final sideways = await side.capture(
        snapshot: snapshot,
        entity: entity,
        scene: Scene(),
      );
      expect(sideways.receipt.camera.forward, [1, 0, 0]);
      expect(() => CameraProfile(forward: Vec3.zero), throwsArgumentError);
      expect(
        () => CameraProfile(forward: const Vec3(0, 1, 0)),
        throwsArgumentError,
      );
    },
  );
}
