import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_ai/visual_v2.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_navigation/zyren_navigation.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'task_scenarios.dart';
import 'visual_v2_oracle.dart';
import 'visual_v2_supervision.dart';

VisualNavigationMap visualV2PublishedMap({bool hiddenPair = false}) {
  final walkable = [
    NavigationGeometry(
      sourceId: 'visual-v2-published-floor',
      revision: '1',
      vertices: const [
        Vec3(-5, 0, -1),
        Vec3(5, 0, -1),
        Vec3(5, 0, 8),
        Vec3(-5, 0, 8),
      ],
      triangles: const [
        [0, 2, 1],
        [0, 3, 2],
      ],
    ),
  ];
  final noEntry = [
    VisualNoEntryPolygon(
      sourceId: 'visual-v2-permanent-no-entry',
      vertices: hiddenPair
          ? const [
              Vec3(-13, 0, 1.85),
              Vec3(13, 0, 1.85),
              Vec3(13, 0, 2.15),
              Vec3(-13, 0, 2.15),
            ]
          : const [
              Vec3(-2, 0, 3.85),
              Vec3(2, 0, 3.85),
              Vec3(2, 0, 4.15),
              Vec3(-2, 0, 4.15),
            ],
    ),
  ];
  final settings = NavigationBakeSettings(
    cellSize: .2,
    radius: .3,
    height: 1.8,
    maxCells: 16384,
  );
  final hash = VisualNavigationMap.contentHash(
    walkable: walkable,
    noEntry: noEntry,
    settings: settings,
  );
  return VisualNavigationMap.fromAuthored(
    expectedHash: hash,
    walkable: walkable,
    noEntry: noEntry,
    settings: settings,
  );
}

/// First vertical is TRAIN-only and combined-camera. No quality plan is registered.
GameTrainingScenario visualV2GuardScenario({
  double? hiddenTargetX,
  void Function(TrainingTaskView)? onPrepared,
  void Function(Map<String, Object?>)? onCleanup,
}) {
  final profile = VisualNavigationProfile(family: 'guard', mode: 'combined');
  final map = visualV2PublishedMap(hiddenPair: hiddenTargetX != null);
  const id = 'guard-visual-nav-combined-v2-train';
  return GameTrainingScenario(
    id: id,
    split: TrainingSplit.training,
    maxSteps: 600,
    create: (seed, episode) async {
      late TrainingTaskView view;
      late VisualGoalController controller;
      VisualCapturePose? captured;
      VisualEstimate? oracle;
      VisualMotionDecision? decision;
      var mountYaw = 0.0, captures = 0, cancelled = false, closed = false;
      List<double> transform(List<double> values) {
        final tick = view.simulation.session.tick;
        final estimate = VisualEstimate.decode(values, profile: profile);
        if (captured != null) {
          controller.accept(
            estimate: estimate,
            captured: captured!,
            tick: tick,
          );
        }
        final state = view.body.state;
        decision = controller.decide(
          tick: tick,
          ownPose: state.pose,
          ownVelocity: state.velocity,
          groundY: 0,
        );
        mountYaw = decision!.cameraYaw;
        return TrainingActions.encodeCharacter(
          decision!.character!,
        ).discrete.map((v) => v.toDouble()).toList();
      }

      final base = await guardScenario(
        id: id,
        stage: 'occlusion',
        targetOriginX: (seed % 7 - 3) * .4,
        hiddenTargetX: hiddenTargetX,
        occluderTick: hiddenTargetX == null ? 61 : 0,
        transformAction: transform,
        onPrepared: (v) {
          view = v;
          onPrepared?.call(v);
        },
      ).create(seed, episode);
      final identity = VisualCaptureIdentity(
        episodeId: episode,
        actor: view.actor,
        profileHash: profile.hash,
        modelHash: '0' * 64,
        mapHash: map.hash,
        gameEpoch: 0,
        controlEpoch: 0,
        stateEpoch: 0,
        cameraRevision: 0,
        mapRevision: 0,
      );
      controller = VisualGoalController(
        profile: profile,
        map: map,
        identity: identity,
        actorShape: view.actorShape!,
        actorOffset: view.actorColliderOffset!,
        obstacleMaxSpeed: 0,
      );
      final sensor = CameraSensor(
        profile.camera,
        openBackend: NativeBackend.create,
      );
      final meshes = <PhysicsBody, Mesh>{};
      view.observerRoot.visible = false;
      view.scene.background = const Color3(0, 0, 0);
      Float32List? latest;
      Map<String, Object?> captureInfo = {};
      void sync() {
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
                'TRAIN raster class has no geometry.',
              ),
            };
            final color = surface.body == view.target
                ? const Color3(1, 0, 0)
                : surface.body.state.pose.position.y < 0
                ? const Color3(0, 1, 0)
                : const Color3(0, 0, 1);
            return view.scene.add(Mesh(geometry, UnlitMaterial(color: color)));
          });
          mesh.position = surface.body.state.pose.position;
          mesh.quaternion = surface.body.state.pose.rotation;
        }
      }

      Future<void> capture() async {
        base.observe();
        sync();
        final tick = base.session.tick;
        if (tick % 5 != 0) return;
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
        final body = profile.ownBody(
          pose: state.pose,
          velocity: state.velocity,
          angularVelocity: state.angularVelocity,
          cameraYaw: mountYaw,
        );
        final result = await sensor.capture(
          snapshot: snapshot,
          entity: view.actor,
          scene: view.scene,
          mountYaw: mountYaw,
        );
        if (cancelled || closed) throw StateError('TRAIN capture cancelled.');
        captured = VisualCapturePose.fromCamera(
          identity: identity,
          profile: profile,
          observation: result,
          groundY: 0,
        );
        latest = Float32List.fromList(
          profile.compose(result.tensor, ownBody: body).float32Values,
        );
        oracle = visualV2RasterOracle(result, profile);
        final labels = visualV2Supervision(
          result,
          profile,
          boxes: [
            for (var i = 0; i < view.surfaces.length; i++)
              if (view.surfaces[i].shape case final BoxShape shape)
                if (view.surfaces[i].body.state.pose.position.y >= 0)
                  VisualV2TrainingBox.fromCapturedWorld(
                    sourceId: 'TRAIN-surface-$i',
                    pose: view.surfaces[i].body.state.pose,
                    shape: shape,
                    captured: result,
                  ),
          ],
        );
        captures++;
        captureInfo = {
          'camera_tick': tick,
          'camera_world_revision': result.worldRevision,
          'camera_captures': captures,
          'camera_mount_yaw': result.capturedMountYaw,
          'camera_cpu_readback_ns': result.receipt.stats.profile?.cpuReadbackNs,
          'camera_source': 'actual-A6-native-readback',
          'oracle_visible': oracle!.target.admitted,
          'TRAIN_supervision': labels.toJson(),
        };
      }

      Future<void> close() async {
        if (closed) return;
        closed = true;
        cancelled = true;
        try {
          await sensor.close();
        } finally {
          await base.close();
          onCleanup?.call({
            'cameraClosed': sensor.isClosed,
            'pendingCaptures': sensor.pendingCount,
            'reservedCaptureBytes': sensor.reservedBytes,
            'worldClosed': view.simulation.world.isClosed,
            'actorAlive': view.body.isAlive,
          });
        }
      }

      try {
        // The reused native task starts at tick one. Advance idle to the first
        // admitted cadence without introducing another simulation clock.
        while (base.session.tick % 5 != 0) {
          base.step();
        }
        await capture();
        return GameTrainingInstance(
          session: base.session,
          step: base.step,
          close: close,
          actors: base.actors,
          afterStep: capture,
          cancelPending: () {
            cancelled = true;
            sensor.invalidate();
          },
          observe: () => {view.actor.id: Float32List.fromList(latest!)},
          observationSchemaHash: profile.spec.hash,
          actionSchemaHash: VisualEstimate.spec.hash,
          actionWidth: 74,
          acceptAction: (v) => VisualEstimate.spec.accepts(v, const []),
          actionSpace: {
            'kind': 'box',
            'low': VisualEstimate.spec.continuous.map((f) => f.min).toList(),
            'high': VisualEstimate.spec.continuous.map((f) => f.max).toList(),
          },
          supportsSnapshot: false,
          reward: () => 0,
          terminal: () => base.session.tick >= 605,
          success: () =>
              view.target != null &&
              (view.target!.state.pose.position - view.body.state.pose.position)
                      .length <
                  .75,
          info: () => {
            ...base.info!(),
            ...captureInfo,
            'visual_profile': profile.toJson(),
            'observation_schema': profile.spec.toJson(),
            'action_schema': VisualEstimate.spec.toJson(),
            'teacher_estimate': oracle!.values,
            'baseline_action': oracle!.values,
            'observation_width': profile.width,
            'delay_ticks': 2,
            'reward_terms': const {'task.progress': 0.0},
            'controller_legality': base.info!()['legality'],
            'controller_execution_legality': base.info!()['execution_legality'],
            'legality': const <List<bool>>[],
            'execution_legality': const <List<bool>>[],
            'controller_configuration': controller.toJson(),
            'controller_configuration_hash': controller.configurationHash,
            'map_hash': map.hash,
            'map_manifest': VisualNavigationMap.manifest(
              walkable: map.walkable,
              noEntry: map.noEntry,
              settings: map.mesh.settings,
            ),
            'motion_state': decision?.state.name,
            'route_diagnostic': controller.route?.points
                .take(5)
                .map((v) => [v.x, v.y, v.z])
                .toList(),
            'goal_observed_tick': controller.belief?.captured.captureTick,
            'goal_sigma': controller.belief?.sigmaAt(base.session.tick),
            'training_only_fields': [
              'TRAIN_supervision',
              'teacher_estimate',
              'baseline_action',
              'controller_legality',
              'controller_execution_legality',
              'route_diagnostic',
              'success',
              'physics_position',
            ],
            'policy_kind': 'TRAIN-raster-oracle-not-learned',
            'activation_allowed': false,
            'scenario_version': 2,
            'scenario_spec': {
              ...(base.info!()['scenario_spec'] as Map<String, Object?>),
              'id': id,
              'observation_schema_hash': profile.spec.hash,
              'action_schema_hash': VisualEstimate.spec.hash,
              'callback_id': 'visual-v2.TRAIN-raster-oracle',
              'max_steps': 600,
              'control_cadence': 5,
              'latency_ticks': 2,
              'settings': {
                'pipeline': 'visual-navigation-v2',
                'task_version': 2,
                'fixed_hz': 50,
                'map_hash': map.hash,
                'controller_hash': controller.configurationHash,
                'raster_fixture': 'red-cue-green-floor-blue-wall',
                'occluder_tick': hiddenTargetX == null ? 61 : 0,
                'no_learning': true,
              },
            },
          },
        );
      } catch (_) {
        await close();
        rethrow;
      }
    },
  );
}
