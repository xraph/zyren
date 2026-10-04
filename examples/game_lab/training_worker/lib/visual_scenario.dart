import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:zyren/zyren.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'task_scenarios.dart';

enum TrainingCameraMode { rgb, depth, combined }

GameTrainingScenario visualTaskScenario({
  required bool vehicle,
  required TrainingCameraMode mode,
  TrainingSplit split = TrainingSplit.training,
  bool heldOut = false,
  double? hiddenTargetX,
}) {
  final id =
      '${vehicle ? 'vehicle' : 'guard'}-visual-${mode.name}${heldOut ? '-evaluation' : ''}';
  final profile = CameraProfile(
    depth: mode != TrainingCameraMode.rgb,
    offset: Vec3(0, vehicle ? .6 : .3, .35),
    far: 40,
    maxMetres: 40,
  );
  final planes = mode == TrainingCameraMode.rgb
      ? 3
      : mode == TrainingCameraMode.depth
      ? 2
      : 5;
  final imageWidth = 84 * 84 * planes;
  final schema = <String, Object?>{
    'version': 1,
    'id': '${vehicle ? 'vehicle' : 'guard'}-visual-${mode.name}',
    'camera_profile': profile.toJson(),
    'mode': mode.name,
    'layout': 'CHW-image-then-own-body',
    'fields': [
      {'id': 'camera', 'width': imageWidth},
      {'id': 'own-body', 'width': 8},
    ],
    'body_fields': [
      'localVelocityX',
      'localVelocityY',
      'localVelocityZ',
      'angularVelocityY',
      'height',
      'forwardGoal',
      'lateralGoal',
      'valid',
    ],
    'augmentation': {
      'rgb_noise_max': .01,
      'texture': 'seeded-native-2x2',
      'lighting_intensity': [.7, 1.3],
    },
    'training_only_fields': ['teacher_action', 'teacher_observation'],
  };
  final observationHash = crypto.sha256
      .convert(utf8.encode(jsonEncode(schema)))
      .toString();
  return GameTrainingScenario(
    id: id,
    split: split,
    maxSteps: 240,
    create: (seed, episode) async {
      late TrainingTaskView view;
      final baseScenario = vehicle
          ? vehicleScenario(
              id: id,
              split: split,
              heldOut: heldOut,
              onPrepared: (v) => view = v,
            )
          : guardScenario(
              id: id,
              split: split,
              heldOut: heldOut,
              hiddenTargetX: hiddenTargetX,
              targetOriginX: (seed % 7 - 3) * (heldOut ? .5 : .4),
              occluderTick: hiddenTargetX == null ? 61 : 0,
              onPrepared: (v) => view = v,
            );
      final base = await baseScenario.create(seed, episode);
      final random = math.Random(seed ^ (heldOut ? 0x6abc : 0x1234));
      final sensor = CameraSensor(profile, openBackend: NativeBackend.create);
      final meshes = <PhysicsBody, Mesh>{};
      view.observerRoot.visible = false;
      view.scene.background = const Color3(.12, .16, .22);
      view.scene.add(HemisphereLight(intensity: .7 + random.nextDouble() * .6));
      view.scene.add(
        DirectionalLight(
          direction: const Vec3(-.4, -1, -.3),
          intensity: .7 + random.nextDouble() * .6,
        ),
      );
      Float32List? cached;
      var cameraCaptures = 0;
      var previousDistance = view.target == null
          ? 0.0
          : (view.target!.state.pose.position - view.body.state.pose.position)
                .length;
      var visualReward = 0.0;
      var teacherWaypoint = 0;
      List<double>? visualTeacher;
      final teacherSide =
          view.target == null || view.target!.state.pose.position.x >= 0
          ? 1.0
          : -1.0;
      Map<String, Object?> cameraInfo = {};
      void synchronizeSurfaces() {
        for (final surface in view.surfaces) {
          final mesh = meshes.putIfAbsent(surface.body, () {
            final geometry = switch (surface.shape) {
              BoxShape(:final halfExtents) => BoxGeometry(
                width: halfExtents.x * 2,
                height: halfExtents.y * 2,
                depth: halfExtents.z * 2,
              ),
              SphereShape(:final radius) => SphereGeometry(radius: radius),
              _ => throw UnsupportedError(
                'Visual task collider is unsupported.',
              ),
            };
            final pixels = Uint8List.fromList([
              for (var i = 0; i < 4; i++) ...[
                40 + random.nextInt(180),
                40 + random.nextInt(180),
                40 + random.nextInt(180),
                255,
              ],
            ]);
            final material = StandardMaterial(
              baseColorMap: TextureMap(
                image: TextureImage.rgba(
                  width: 2,
                  height: 2,
                  pixels: pixels,
                  format: TextureFormat.rgba8UnormSrgb,
                ),
              ),
              roughness: .8,
            );
            return view.scene.add(Mesh(geometry, material));
          });
          final pose = surface.body.state.pose;
          mesh.position = pose.position;
          mesh.quaternion = pose.rotation;
        }
      }

      Future<void> capture() async {
        // Update authored events and the structured teacher once at this completed tick.
        base.observe();
        synchronizeSurfaces();
        final tick = base.session.tick;
        final snapshot = SensorSnapshot.fromSimulation(
          episodeId: episode,
          worldRevision: tick,
          simulation: view.simulation,
          bindings: {view.actor: view.body},
          colliders: {},
          currentRevision: () => base.session.tick,
          geometryLoaded: (_, _) => true,
        );
        final observation = await sensor.capture(
          snapshot: snapshot,
          entity: view.actor,
          scene: view.scene,
        );
        final values = observation.tensor.float32Values;
        final image = mode == TrainingCameraMode.depth
            ? values.sublist(84 * 84 * 3)
            : values;
        final result = Float32List(imageWidth + 8);
        result.setRange(0, imageWidth, image);
        if (mode != TrainingCameraMode.depth) {
          for (var i = 0; i < 84 * 84 * 3; i++) {
            result[i] = (result[i] + (random.nextDouble() * 2 - 1) * .01).clamp(
              0,
              1,
            );
          }
        }
        final state = view.body.state, q = state.pose.rotation;
        final local = Quat(-q.x, -q.y, -q.z, q.w).rotate(state.velocity);
        result.setRange(imageWidth, result.length, [
          local.x,
          local.y,
          local.z,
          state.angularVelocity.y,
          state.pose.position.y,
          1,
          0,
          1,
        ]);
        cached = result;
        if (view.target != null) {
          final distance =
              (view.target!.state.pose.position - view.body.state.pose.position)
                  .length;
          visualReward = (previousDistance - distance).clamp(-1, 1);
          previousDistance = distance;
        } else {
          visualReward = base.reward();
        }
        if (view.target != null) {
          // Privileged demonstration labels stay outside the student tensor.
          final position = state.pose.position;
          final waypoints = [
            Vec3(teacherSide * 2.55, .81, 3.3),
            Vec3(teacherSide * 2.55, .81, 4.65),
            view.target!.state.pose.position,
          ];
          if (teacherWaypoint < 2 &&
              (waypoints[teacherWaypoint] - position).length < .35) {
            teacherWaypoint++;
          }
          final delta = waypoints[teacherWaypoint] - position;
          final horizontal = Vec3(delta.x, 0, delta.z);
          final direction = horizontal.length < .3
              ? Vec3.zero
              : horizontal.normalized();
          visualTeacher = TrainingActions.encodeCharacter(
            CharacterIntent(moveX: direction.x, moveZ: direction.z),
          ).discrete.map((v) => v.toDouble()).toList();
        }
        cameraCaptures++;
        cameraInfo = {
          'camera_tick': tick,
          'camera_world_revision': observation.worldRevision,
          'camera_captures': cameraCaptures,
          'camera_request': observation.receipt.requestId,
          'camera_width': 84,
          'camera_height': 84,
          'camera_mode': mode.name,
          'camera_cpu_readback_ns':
              observation.receipt.stats.profile?.cpuReadbackNs,
          'renderer': 'native',
          'visual_source': 'actual-native-readback',
        };
      }

      Future<void> close() async {
        try {
          await sensor.close();
        } finally {
          await base.close();
        }
      }

      try {
        await capture();
        return GameTrainingInstance(
          session: base.session,
          step: base.step,
          close: close,
          actors: base.actors,
          beforeStep: base.beforeStep,
          afterStep: capture,
          cancelPending: sensor.invalidate,
          observe: () => {view.actor.id: Float32List.fromList(cached!)},
          observationSchemaHash: observationHash,
          actionSchemaHash: base.actionSchemaHash,
          actionWidth: base.actionWidth,
          acceptAction: base.acceptAction,
          actionSpace: base.actionSpace,
          supportsSnapshot: false,
          reward: () => visualReward,
          terminal: base.terminal,
          success: () =>
              view.target == null ? base.success() : previousDistance < .75,
          info: () {
            final info = base.info!();
            return {
              ...info,
              ...cameraInfo,
              'observation_schema': schema,
              'observation_width': imageWidth + 8,
              'teacher_action': visualTeacher ?? info['baseline_action'],
              'baseline_action': visualTeacher ?? info['baseline_action'],
              'teacher_source': vehicle
                  ? 'structured-permitted'
                  : 'privileged-training-only-route',
              'reward_terms': {'task.progress': visualReward},
              'task_success_radius': vehicle ? null : .75,
              'scenario_spec': {
                ...info['scenario_spec'] as Map,
                'observation_schema_hash': observationHash,
                'settings': {
                  ...(info['scenario_spec'] as Map)['settings'] as Map,
                  'camera_profile': profile.toJson(),
                  'camera_mode': mode.name,
                  'visual': true,
                },
              },
            };
          },
        );
      } catch (_) {
        await close();
        rethrow;
      }
    },
  );
}

Map<String, GameTrainingScenario> visualScenarioCatalog({
  bool evaluation = false,
}) => {
  for (final vehicle in [false, true])
    for (final mode in TrainingCameraMode.values)
      '${vehicle ? 'vehicle' : 'guard'}-visual-${mode.name}${evaluation ? '-evaluation' : ''}':
          visualTaskScenario(
            vehicle: vehicle,
            mode: mode,
            heldOut: evaluation,
            split: evaluation ? TrainingSplit.test : TrainingSplit.training,
          ),
};
