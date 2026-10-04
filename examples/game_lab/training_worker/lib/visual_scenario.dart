import 'dart:math' as math;
import 'dart:typed_data';
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
  String? scenarioId,
  String? stage,
  double targetSpeed = 0,
  int? occluderTick,
}) {
  final id =
      scenarioId ??
      '${vehicle ? 'vehicle' : 'guard'}-visual-${mode.name}${heldOut ? '-evaluation' : ''}';
  final visual = TrainingVisualProfiles.forFamily(
    family: vehicle ? 'vehicle' : 'guard',
    mode: mode.name,
  );
  final profile = visual.camera;
  final imageWidth = visual.imageWidth;
  final schema = visual.spec.toJson();
  final observationHash = visual.spec.hash;
  return GameTrainingScenario(
    id: id,
    split: split,
    maxSteps: vehicle ? 240 : 600,
    create: (seed, episode) async {
      late TrainingTaskView view;
      final baseScenario = vehicle
          ? vehicleScenario(
              id: id,
              split: split,
              heldOut: heldOut,
              stage: stage ?? 'static-obstacles',
              onPrepared: (v) => view = v,
            )
          : guardScenario(
              id: id,
              split: split,
              heldOut: heldOut,
              hiddenTargetX: hiddenTargetX,
              stage: stage ?? 'occlusion',
              targetSpeed: targetSpeed,
              targetOriginX: (seed % 7 - 3) * (heldOut ? .5 : .4),
              occluderTick: occluderTick ?? (hiddenTargetX == null ? 61 : 0),
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
        final state = view.body.state;
        final ownBody = visual.ownBody(
          pose: state.pose,
          velocity: state.velocity,
          angularVelocity: state.angularVelocity,
        );
        final observation = await sensor.capture(
          snapshot: snapshot,
          entity: view.actor,
          scene: view.scene,
        );
        final result = Float32List.fromList(
          visual.compose(observation.tensor, ownBody: ownBody).float32Values,
        );
        if (mode != TrainingCameraMode.depth) {
          for (var i = 0; i < 84 * 84 * 3; i++) {
            result[i] = (result[i] + (random.nextDouble() * 2 - 1) * .01).clamp(
              0,
              1,
            );
          }
        }
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
          final direction = horizontal.length < (teacherWaypoint == 2 ? .7 : .3)
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
          terminal: vehicle ? base.terminal : () => base.session.tick >= 601,
          success: () =>
              view.target == null ? base.success() : previousDistance < .75,
          info: () {
            final info = base.info!();
            return {
              ...info,
              ...cameraInfo,
              'observation_schema': schema,
              'visual_profile': visual.toJson(),
              'visual_augmentation': {
                'rgb_noise_max': .01,
                'texture': 'seeded-native-2x2',
                'lighting_intensity': [.7, 1.3],
              },
              'training_only_fields': ['teacher_action', 'teacher_observation'],
              'observation_width': imageWidth + 8,
              'teacher_action': visualTeacher ?? info['baseline_action'],
              'baseline_action': visualTeacher ?? info['baseline_action'],
              'teacher_source': vehicle
                  ? 'structured-permitted'
                  : 'privileged-training-only-route',
              'reward_terms': {'task.progress': visualReward},
              'task_success_radius': vehicle ? null : .75,
              if (!vehicle) 'task_remaining_distance': previousDistance,
              if (!vehicle)
                'reward_progress_basis': 'remaining-distance-decrease',
              'scenario_spec': {
                ...info['scenario_spec'] as Map,
                'observation_schema_hash': observationHash,
                'max_steps': vehicle ? 240 : 600,
                'settings': {
                  ...(info['scenario_spec'] as Map)['settings'] as Map,
                  'camera_profile': profile.toJson(),
                  'camera_mode': mode.name,
                  'visual': true,
                  if (!vehicle)
                    'target_offset_domain': heldOut ? [-1.5, 1.5] : [-1.2, 1.2],
                  if (!vehicle)
                    'teacher_waypoints': [
                      [2.55, 3.3],
                      [2.55, 4.65],
                    ],
                  if (!vehicle) 'teacher_route_rule': 'target-side-sign',
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
  bool validation = false,
}) {
  if (evaluation && validation) {
    throw ArgumentError('Visual catalog has one held-out partition.');
  }
  final heldOut = evaluation || validation;
  final result = <String, GameTrainingScenario>{};
  void add(
    bool vehicle,
    TrainingCameraMode mode,
    String suffix, {
    String stage = 'occlusion',
    double targetSpeed = 0,
    double? hiddenTargetX,
    int? occluderTick,
  }) {
    final id = '${vehicle ? 'vehicle' : 'guard'}-visual-${mode.name}$suffix';
    result[id] = visualTaskScenario(
      scenarioId: id,
      vehicle: vehicle,
      mode: mode,
      heldOut: heldOut,
      split: evaluation
          ? TrainingSplit.test
          : validation
          ? TrainingSplit.validation
          : TrainingSplit.training,
      stage: stage,
      targetSpeed: targetSpeed,
      hiddenTargetX: hiddenTargetX,
      occluderTick: occluderTick,
    );
  }

  for (final vehicle in [false, true]) {
    for (final mode in TrainingCameraMode.values) {
      add(
        vehicle,
        mode,
        evaluation
            ? '-evaluation'
            : validation
            ? '-validation'
            : '',
        stage: vehicle ? 'static-obstacles' : 'occlusion',
      );
      if (evaluation) {
        add(vehicle, mode, '-recovery', stage: 'task-combinations');
        if (!vehicle) {
          add(false, mode, '-memory', targetSpeed: .15, occluderTick: 41);
          add(false, mode, '-paired-left', hiddenTargetX: -3, occluderTick: 0);
          add(false, mode, '-paired-right', hiddenTargetX: 3, occluderTick: 0);
        }
      } else if (!validation) {
        for (final stage in trainingCurriculumStages) {
          add(vehicle, mode, '-$stage', stage: stage);
        }
      }
    }
  }
  return result;
}
