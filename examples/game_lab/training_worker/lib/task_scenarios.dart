import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:convert';
import 'package:crypto/crypto.dart' as crypto;
import 'package:zyren/zyren.dart';
import 'package:zyren_characters/zyren_characters.dart';
import 'package:zyren_characters/physics.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'package:zyren_gltf_timeline/zyren_gltf_timeline.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'assets/skinned_character_asset.dart';
import 'clock_renderer.dart';

CompiledGameProject _project(
  String id,
  List<String> entities,
  Map<String, int> versions,
) => CompiledGameProject(
  project: GameProject(
    id: id,
    startupLevel: 'arena',
    registry: GameRegistry(),
    levels: [
      GameLevel(
        id: 'arena',
        scene: GameSceneIdentity('authored-arena', '1'),
        entities: [for (final id in entities) GameEntityRecord(id: id)],
      ),
    ],
  ),
  systemVersions: versions,
  fixedHz: 50,
);

final class TrainingTaskSurface {
  final PhysicsBody body;
  final ColliderShape shape;
  const TrainingTaskSurface(this.body, this.shape);
}

final class TrainingTaskView {
  final Scene scene;
  final GameSimulation simulation;
  final GameEntityHandle actor;
  final PhysicsBody body;
  final Object3D observerRoot;
  final List<TrainingTaskSurface> surfaces;
  final PhysicsBody? target;
  const TrainingTaskView(
    this.scene,
    this.simulation,
    this.actor,
    this.body,
    this.observerRoot,
    this.surfaces, {
    this.target,
  });
}

PhysicsBody _box(
  PhysicsWorld world,
  Vec3 center,
  Vec3 half, {
  double friction = .5,
  Set<int>? capture,
  List<TrainingTaskSurface>? surfaces,
}) {
  final body = world.createBody(
    kind: BodyKind.fixed,
    pose: PhysicsPose(position: center),
  );
  final shape = BoxShape(half);
  final collider = body.addCollider(shape, friction: friction);
  surfaces?.add(TrainingTaskSurface(body, shape));
  capture?.add(collider.id);
  return body;
}

/// Pursuit becomes investigation after an authored opaque wall closes sight.
GameTrainingScenario guardScenario({
  String id = 'guard',
  String stage = 'occlusion',
  TrainingSplit split = TrainingSplit.training,
  bool heldOut = false,
  double targetSpeed = 0,
  int occluderTick = 61,
  double? hiddenTargetX,
  double? targetOriginX,
  void Function(TrainingTaskView)? onPrepared,
}) => GameTrainingScenario(
  id: id,
  split: split,
  maxSteps: 240,
  create: (seed, episode) async {
    final world = PhysicsWorld(fixedStep: .02);
    final surfaces = <TrainingTaskSurface>[];
    PhysicsBody box(
      Vec3 center,
      Vec3 half, {
      double friction = .5,
      Set<int>? capture,
    }) => _box(
      world,
      center,
      half,
      friction: friction,
      capture: capture,
      surfaces: surfaces,
    );
    final assets = AssetScope(
      services: AssetServices(resolver: SkinnedCharacterSource()),
    );
    GameSimulation? simulation;
    SceneEngine? engine;
    Registration? connection, registration;
    ScriptedBrain? brain;
    try {
      final ground = <int>{};
      final friction = heldOut ? .35 + (seed % 7) * .05 : .5;
      box(
        const Vec3(0, -.5, 0),
        const Vec3(20, .5, 20),
        friction: friction,
        capture: ground,
      );
      final source = await assets.load(Gltf.asset('skin.gltf')).result;
      final model = source.instantiate(nativeDeformation: false);
      final scene = Scene(), root = Group();
      scene.add(root);
      root.add(model);
      model.position = const Vec3(0, -.8, 0);
      final body = world.createBody(
        kind: BodyKind.kinematicPosition,
        pose: PhysicsPose(position: const Vec3(0, .81, 0)),
      );
      final collider = body.addCollider(
        const CapsuleShape(halfHeight: .5, radius: .3),
      );
      PhysicsBody? hazard;
      if (stage == 'static-obstacles' || stage == 'task-combinations') {
        box(const Vec3(.8, .5, 2), const Vec3(.5, .5, .4));
      }
      if (stage == 'moving-hazards' || stage == 'task-combinations') {
        hazard = world.createBody(
          kind: BodyKind.kinematicPosition,
          pose: PhysicsPose(position: const Vec3(-2, .6, 3)),
        )..addCollider(const BoxShape(Vec3(.4, .6, .4)));
      }
      if (hazard != null) {
        surfaces.add(
          TrainingTaskSurface(hazard, const BoxShape(Vec3(.4, .6, .4))),
        );
      }
      final targetOrigin = Vec3(
        hiddenTargetX ?? targetOriginX ?? (heldOut ? (seed % 5 - 2) * .5 : 0),
        .81,
        heldOut ? 6 + (seed % 7) * .1 : 6,
      );
      final targetBody = world.createBody(
        kind: targetSpeed == 0 ? BodyKind.fixed : BodyKind.kinematicPosition,
        pose: PhysicsPose(position: targetOrigin),
      );
      final targetCollider = targetBody.addCollider(const SphereShape(.25));
      surfaces.add(TrainingTaskSurface(targetBody, const SphereShape(.25)));
      final timeline = SceneTimelinePlugin.mixed(
        duration: const Duration(seconds: 1),
        base: modelRestClip(model),
      )..externallyDriven = true;
      final animation = CharacterAnimationPlugin(
        timeline: timeline,
        states: [
          CharacterState.rest('idle', model),
          CharacterState.animation('walk', model, model.animations.single),
        ],
        transitions: [
          CharacterTransition('idle', 'walk'),
          CharacterTransition('walk', 'idle'),
        ],
        initialState: 'idle',
      );
      final motor = CharacterMotor(
        character: animation,
        rootMotion: RootMotion(model, root: 0),
        controller: KinematicCharacterController(
          body: body,
          collider: collider,
        ),
      );
      final motors = GameCharacterMotorRegistry(world);
      final physics = PhysicsPlugin(
        world: world,
        externallyDriven: true,
        interpolate: false,
        beforeStep: motors.advance,
      );
      final commands = _TaskCommands();
      final owner = GameSimulation(
        project: _project(
          id == 'guard' ? 'guard-pursuit-v1' : 'guard-$stage-v1',
          ['actor', 'target'],
          {'training.task-actions': 1},
        ),
        seed: seed,
        physics: physics,
        systems: [commands],
        ownsWorld: true,
      );
      simulation = owner;
      connection = motors.connect(owner);
      engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(),
        rendererFactory: () async => TrainingClockRenderer(),
        plugins: [timeline, animation, physics],
      );
      owner.step();
      final actor = owner.session.entities.entities
          .singleWhere((e) => e.handle.id == 'actor')
          .handle;
      final target = owner.session.entities.entities
          .singleWhere((e) => e.handle.id == 'target')
          .handle;
      final controller = GameCharacterController(
        actor: actor,
        session: owner.session,
        motor: motor,
        definition: GameCharacterDefinition(maxSpeed: 2),
      );
      registration = motors.register(controller, root);
      onPrepared?.call(
        TrainingTaskView(
          scene,
          owner,
          actor,
          body,
          root,
          surfaces,
          target: targetBody,
        ),
      );
      final decoder = ActionDecoder.characterDiscrete();
      final assembler = TrainingProfiles.guard();
      final script = ScriptedBrain(
        identity: BrainIdentity(
          episodeId: episode,
          entity: actor,
          modelHash: 'scripted-v1',
        ),
        entities: owner.session.entities,
      );
      brain = script;
      final captures = <int, PhysicsPose>{};
      final colliders = <int, SensorCollider>{
        targetCollider.id: SensorCollider(
          SensorMaterial.opaque,
          entity: target,
        ),
      };
      List<double> applied = decoder.spec.fallbackDiscrete
          .map((v) => v.toDouble())
          .toList();
      List<double> baseline = List.of(applied);
      bool fallback = false;
      String mode = 'pursuit';
      ObservationFrame? frame;
      var progress = 0.0, lastZ = body.state.pose.position.z;
      PhysicsBody? wall;
      List<List<bool>> currentLegality() {
        final result = [
          for (final branch in decoder.spec.branches)
            List.filled(branch.choices.length, true),
        ];
        result[4][1] = controller.grounded;
        // This scenario registers no interaction service. Never expose a hidden target range.
        result[5][1] = false;
        return result;
      }

      List<List<bool>> executionLegality = currentLegality();
      commands.apply = (values) {
        final policy = PolicyAction([], values.map((v) => v.toInt()).toList());
        final legality = currentLegality();
        executionLegality = legality;
        final decoded = decoder.decode(policy, legality: legality);
        fallback = decoded == null;
        final actual = decoded ?? decoder.fallback;
        controller.apply(actual.character!);
        applied = actual.action.discrete.map((v) => v.toDouble()).toList();
      };
      Map<String, Float32List> observe() {
        // Occluder placement is a registered scenario event, not a policy input.
        if ((stage == 'occlusion' || stage == 'task-combinations') &&
            owner.session.tick >= occluderTick &&
            wall == null) {
          wall = box(
            Vec3(0, 1, hiddenTargetX == null ? 4 : 2),
            Vec3(hiddenTargetX == null ? 2 : 12, 1, .15),
          );
          // The wall metadata defaults to blocking through the authored opaque profile.
        }
        if (targetSpeed != 0) {
          targetBody.setTarget(
            PhysicsPose(
              position:
                  targetOrigin +
                  Vec3(0, 0, targetSpeed * owner.session.tick * .02),
            ),
          );
        }
        hazard?.setTarget(
          PhysicsPose(
            position: Vec3(math.sin(owner.session.tick * .04) * 2, .6, 3),
          ),
        );
        final snapshot = SensorSnapshot.fromSimulation(
          episodeId: episode,
          worldRevision: owner.session.tick,
          simulation: owner,
          bindings: {actor: body, target: targetBody},
          characters: [controller],
          colliders: colliders,
          currentRevision: () => owner.session.tick,
          geometryLoaded: (_, _) => true,
        );
        frame = assembler.build(snapshot, actor);
        captures[frame!.tick] = body.state.pose;
        captures.removeWhere((tick, _) => tick < owner.session.tick - 240);
        script.observe(frame!);
        final beliefs = script.memory.atTick(owner.session.tick);
        final belief = beliefs
            .where(
              (b) =>
                  b.position != null &&
                  b.target == target &&
                  captures.containsKey(b.observedTick),
            )
            .firstOrNull;
        final goals = <GameGoal>[];
        if (belief != null) {
          final captured = captures[belief.observedTick]!;
          final observedWorld =
              captured.position + captured.rotation.rotate(belief.position!);
          final ownPose = body.state.pose;
          final route = Quat(
            -ownPose.rotation.x,
            -ownPose.rotation.y,
            -ownPose.rotation.z,
            ownPose.rotation.w,
          ).rotate(observedWorld - ownPose.position);
          mode = belief.ageTicks == 0 ? 'pursuit' : 'investigation';
          goals.add(
            GameGoal(
              id: mode,
              skill: 'follow-route',
              target: target,
              route: [route],
            ),
          );
        } else {
          mode = 'idle';
        }
        final decision = script.decide(
          BrainContext(
            identity: script.identity,
            tick: owner.session.tick,
            observation: frame,
            beliefs: beliefs,
            goals: goals,
            validTargets: {target},
            actionSpec: script.actionSpec,
          ),
        );
        var intent = const CharacterIntent();
        for (final action in decision.actions) {
          if (action.action == 'ai.move') {
            final worldAxes = body.state.pose.rotation.rotate(
              Vec3(
                (action.arguments['moveX'] as num).toDouble(),
                0,
                (action.arguments['moveZ'] as num).toDouble(),
              ),
            );
            intent = CharacterIntent(
              moveX: worldAxes.x.clamp(-1, 1),
              moveZ: worldAxes.z.clamp(-1, 1),
            );
          }
        }
        baseline = TrainingActions.encodeCharacter(
          intent,
        ).discrete.map((v) => v.toDouble()).toList();
        final z = body.state.pose.position.z;
        progress = (z - lastZ).clamp(-1, 1);
        lastZ = z;
        return {actor.id: Float32List.fromList(frame!.tensor.float32Values)};
      }

      final pinnedScenario = _scenarioSpec(
        id,
        seed,
        owner.session.project.buildId,
        assembler.spec.hash,
        decoder.spec.hash,
        partition: split.name == 'training' ? 'train' : split.name,
        assets: [
          {
            'id': 'guard-skin',
            'source': 'repository-authored',
            'license': 'LicenseRef-Repository-Authored',
            'hash': crypto.sha256.convert(skinnedCharacterGltf()).toString(),
          },
        ],
        settings: {
          'map': 'guard-arena-v1',
          'occluder_tick': occluderTick,
          'fixed_hz': 50,
          if (id != 'guard') 'curriculum_stage': stage,
          if (heldOut) 'held_out_layout': 'guard-evaluation-v1',
          if (heldOut) 'friction_range': [.35, .65],
          if (heldOut) 'target_offset_domain': [-1.0, 1.0],
          if (targetSpeed != 0) 'target_speed': targetSpeed,
          'hidden_target_x': ?hiddenTargetX,
        },
      );
      return GameTrainingInstance(
        session: owner.session,
        step: owner.step,
        close: () async {
          registration?.dispose();
          connection?.dispose();
          await script.close();
          await engine?.dispose();
          await owner.close();
          await assets.close();
        },
        actors: () => [actor],
        observe: observe,
        observationSchemaHash: assembler.spec.hash,
        actionSchemaHash: decoder.spec.hash,
        supportsSnapshot: false,
        actionWidth: 6,
        acceptAction: (v) =>
            decoder.spec.accepts([], v.map((n) => n.toInt()).toList()) &&
            v.every((n) => n == n.roundToDouble()),
        actionSpace: {
          'kind': 'multi_discrete',
          'nvec': [5, 5, 5, 3, 2, 2],
        },
        reward: () => progress,
        terminal: () => owner.session.tick >= 241,
        success: () => body.state.pose.position.z > 3,
        info: () => {
          'scenario_spec': pinnedScenario,
          'baseline_action': baseline,
          'legality': currentLegality(),
          'execution_legality': executionLegality,
          'accepted_action': applied,
          'fallback': fallback,
          'delay_ticks': 1,
          'reward_terms': {'task.progress': progress},
          'task_mode': mode,
          'collision':
              motor.lastMovement?.contacts.any(
                (contact) => !ground.contains(contact.collider),
              ) ??
              false,
          'physics_friction': friction,
          'physics_position': body.state.pose.position.storage,
          'physics_backend': 'rapier',
          'renderer': null,
          'observation_width': assembler.spec.width,
          'observation_schema': assembler.spec.toJson(),
          'action_schema': decoder.spec.toJson(),
        },
      );
    } catch (_) {
      registration?.dispose();
      connection?.dispose();
      await brain?.close();
      await engine?.dispose();
      await simulation?.close();
      if (!world.isClosed) world.close();
      await assets.close();
      rethrow;
    }
  },
);

final class _TaskCommands extends GameSystem {
  void Function(List<double>)? apply;
  @override
  String get id => 'training.task-actions';
  @override
  GamePhase get phase => GamePhase.commands;
  @override
  void fixedUpdate(GameSession session) {
    for (final command in session.currentCommands) {
      final p = command.payload;
      if (p is Map && p['action'] is List) {
        apply?.call([
          for (final v in p['action'] as List) (v as num).toDouble(),
        ]);
      }
    }
  }
}

GameTrainingScenario vehicleScenario({
  String id = 'vehicle',
  String stage = 'static-obstacles',
  TrainingSplit split = TrainingSplit.training,
  bool heldOut = false,
  void Function(TrainingTaskView)? onPrepared,
}) => GameTrainingScenario(
  id: id,
  split: split,
  maxSteps: 240,
  create: (seed, episode) async {
    final world = PhysicsWorld(fixedStep: .02);
    final surfaces = <TrainingTaskSurface>[];
    PhysicsBody box(
      Vec3 center,
      Vec3 half, {
      double friction = .5,
      Set<int>? capture,
    }) => _box(
      world,
      center,
      half,
      friction: friction,
      capture: capture,
      surfaces: surfaces,
    );
    GameSimulation? simulation;
    ScriptedBrain? brain;
    GameVehicleRegistration? registration;
    try {
      final ground = <int>{};
      final friction = heldOut ? .35 + (seed % 7) * .05 : .5;
      final barrierZ = heldOut ? 11 + (seed % 5) * .5 : 12.0;
      box(
        const Vec3(0, -.1, 0),
        const Vec3(100, .1, 100),
        friction: friction,
        capture: ground,
      );
      if (stage != 'empty-arena') {
        box(Vec3(0, .5, barrierZ), const Vec3(2, .5, .25));
      }
      if (stage == 'occlusion' || stage == 'task-combinations') {
        box(const Vec3(2, 1, 8), const Vec3(.25, 1, 2));
      }
      PhysicsBody? hazard;
      if (stage == 'moving-hazards' || stage == 'task-combinations') {
        hazard = world.createBody(
          kind: BodyKind.kinematicPosition,
          pose: PhysicsPose(position: const Vec3(-3, .5, 7)),
        )..addCollider(const BoxShape(Vec3(.6, .5, .6)));
      }
      if (hazard != null) {
        surfaces.add(
          TrainingTaskSurface(hazard, const BoxShape(Vec3(.6, .5, .6))),
        );
      }
      final body = world.createBody(
        pose: PhysicsPose(position: const Vec3(0, .8, 0)),
        mass: 400,
        inertia: const Vec3(200, 277, 94),
        canSleep: false,
        linearDamping: .01,
        angularDamping: .15,
        ccd: true,
      );
      final chassis = body.addCollider(
        const BoxShape(Vec3(.8, .25, 1.2)),
        density: 0,
      );
      final definition = VehicleDefinition(
        wheels: [
          for (final x in [-.7, .7])
            for (final z in [-1.0, 1.0])
              WheelDefinition(
                id: '$x:$z',
                mount: Vec3(x, 0, z),
                steering: z > 0,
              ),
        ],
      );
      var collision = false;
      final physics = PhysicsPlugin(
        world: world,
        externallyDriven: true,
        interpolate: false,
        onEvents: (events) {
          collision |= events.any(
            (event) =>
                event.kind == 'collision' &&
                event.started &&
                (event.collider1 == chassis.id ||
                    event.collider2 == chassis.id) &&
                !ground.contains(event.collider1) &&
                !ground.contains(event.collider2),
          );
        },
      );
      final vehicles = GameVehicleSystem(world: world, physics: physics);
      final commands = _TaskCommands();
      final owner = GameSimulation(
        project: _project(
          id == 'vehicle' ? 'vehicle-braking-v1' : 'vehicle-$stage-v1',
          ['actor'],
          {
            'training.task-actions': 1,
            'game.vehicles': 1,
            'game.vehicle-presentation': 1,
          },
        ),
        seed: seed,
        physics: physics,
        systems: [commands, vehicles, GameVehiclePresentationSystem(vehicles)],
        ownsWorld: true,
      );
      simulation = owner;
      owner.step();
      final actor = owner.session.entities.entities.single.handle;
      final controller = VehicleController(
        session: owner.session,
        actor: actor,
        body: body,
        definition: definition,
      );
      final root = Group();
      final scene = Scene()..add(root);
      onPrepared?.call(
        TrainingTaskView(scene, owner, actor, body, root, surfaces),
      );
      registration = vehicles.register(
        controller,
        presentationRoot: root,
        wheelVisuals: [for (var i = 0; i < 4; i++) root.add(Group())],
      );
      final decoder = ActionDecoder.vehiclePedals();
      final assembler = TrainingProfiles.vehicle();
      final script = ScriptedBrain(
        identity: BrainIdentity(
          episodeId: episode,
          entity: actor,
          modelHash: 'scripted-v1',
        ),
        entities: owner.session.entities,
        driver: true,
      );
      brain = script;
      List<double> applied = [0, 0, 1], baseline = List.of(applied);
      bool fallback = false;
      var progress = 0.0, lastZ = body.state.pose.position.z;
      commands.apply = (values) {
        final decoded = decoder.decode(PolicyAction(values, []));
        fallback = decoded == null;
        final actual = decoded ?? decoder.fallback;
        controller.apply(actual.vehicle!);
        applied = actual.action.continuous;
      };
      Map<String, Float32List> observe() {
        hazard?.setTarget(
          PhysicsPose(
            position: Vec3(math.sin(owner.session.tick * .03) * 3, .5, 7),
          ),
        );
        final snapshot = SensorSnapshot.fromSimulation(
          episodeId: episode,
          worldRevision: owner.session.tick,
          simulation: owner,
          bindings: {actor: body},
          colliders: {},
          currentRevision: () => owner.session.tick,
          geometryLoaded: (_, _) => true,
        );
        final frame = assembler.build(snapshot, actor);
        script.observe(frame);
        final decision = script.decide(
          BrainContext(
            identity: script.identity,
            tick: owner.session.tick,
            observation: frame,
            beliefs: script.memory.atTick(owner.session.tick),
            goals: const [],
            actionSpec: script.actionSpec,
          ),
        );
        var intent = const VehicleIntent(brake: 1);
        for (final action in decision.actions) {
          if (action.action == 'ai.drive') {
            intent = VehicleIntent(
              steer: (action.arguments['steering'] as num).toDouble(),
              throttle: (action.arguments['throttle'] as num).toDouble(),
              brake: (action.arguments['brake'] as num).toDouble(),
            );
          }
        }
        // Authored turning segment is part of this registered task, never a hidden target lookup.
        baseline = TrainingActions.encodeVehicle(
          VehicleIntent(
            steer: owner.session.tick < 100 ? .35 : intent.steer,
            throttle: owner.session.tick < 160 ? intent.throttle : 0,
            brake: owner.session.tick < 160 ? intent.brake : 1,
          ),
        ).continuous;
        final z = body.state.pose.position.z;
        progress = (z - lastZ).clamp(-1, 1);
        lastZ = z;
        return {actor.id: Float32List.fromList(frame.tensor.float32Values)};
      }

      final pinnedScenario = _scenarioSpec(
        id,
        seed,
        owner.session.project.buildId,
        assembler.spec.hash,
        decoder.spec.hash,
        partition: split.name == 'training' ? 'train' : split.name,
        assets: [
          {
            'id': 'ray-wheel-buggy',
            'source': 'repository-authored',
            'license': 'LicenseRef-Repository-Authored',
            'hash': crypto.sha256
                .convert(utf8.encode(jsonEncode(definition.toJson())))
                .toString(),
          },
        ],
        settings: {
          'map': 'vehicle-arena-v1',
          'turn_until_tick': 100,
          'brake_from_tick': 160,
          'fixed_hz': 50,
          if (id != 'vehicle') 'curriculum_stage': stage,
          if (heldOut) 'held_out_layout': 'vehicle-evaluation-v1',
          if (heldOut) 'friction_range': [.35, .65],
          if (heldOut) 'barrier_z_domain': [11.0, 13.0],
        },
      );
      return GameTrainingInstance(
        session: owner.session,
        step: owner.step,
        close: () async {
          registration?.dispose();
          await script.close();
          await owner.close();
        },
        actors: () => [actor],
        observe: observe,
        observationSchemaHash: assembler.spec.hash,
        actionSchemaHash: decoder.spec.hash,
        actionWidth: 3,
        acceptAction: (values) => decoder.spec.accepts(values.toList(), []),
        supportsSnapshot: false,
        actionSpace: {
          'kind': 'box',
          'low': [-1.0, 0.0, 0.0],
          'high': [1.0, 1.0, 1.0],
        },
        reward: () => progress,
        terminal: () => owner.session.tick >= 241,
        success: () =>
            body.state.pose.position.z > 2 &&
            controller.telemetry.velocity.length < .5,
        info: () => {
          'scenario_spec': pinnedScenario,
          'baseline_action': baseline,
          'accepted_action': applied,
          'fallback': fallback,
          'delay_ticks': 1,
          'reward_terms': {'task.progress': progress},
          'physics_position': body.state.pose.position.storage,
          'physics_backend': 'rapier',
          'renderer': null,
          'observation_width': assembler.spec.width,
          'observation_schema': assembler.spec.toJson(),
          'action_schema': decoder.spec.toJson(),
          'vehicle_speed': controller.telemetry.velocity.length,
          'collision': collision,
          'physics_friction': friction,
          'grounded_wheels': controller.telemetry.groundedWheels,
        },
      );
    } catch (_) {
      registration?.dispose();
      await brain?.close();
      await simulation?.close();
      if (!world.isClosed) world.close();
      rethrow;
    }
  },
);

Map<String, Object?> _scenarioSpec(
  String id,
  int seed,
  String build,
  String observation,
  String action, {
  required List<Map<String, Object?>> assets,
  required Map<String, Object?> settings,
  String partition = 'train',
}) => {
  'schema_version': 1,
  'id': id,
  'partition': partition,
  'game_build_hash': build,
  'observation_schema_hash': observation,
  'action_schema_hash': action,
  'callback_id': id.startsWith('guard')
      ? 'guard.pursuit'
      : 'vehicle.braking-turning',
  'reward_terms': [
    {'id': 'task.progress', 'cap': 1.0},
  ],
  'seed': seed,
  'max_steps': 240,
  'control_cadence': 1,
  'latency_ticks': 1,
  'assets': assets,
  'settings': settings,
};

const trainingCurriculumStages = [
  'empty-arena',
  'static-obstacles',
  'occlusion',
  'moving-hazards',
  'task-combinations',
];

Map<String, GameTrainingScenario> taskScenarioCatalog() => {
  'guard': guardScenario(),
  'vehicle': vehicleScenario(),
  for (final stage in trainingCurriculumStages)
    'guard-$stage': guardScenario(id: 'guard-$stage', stage: stage),
  for (final stage in trainingCurriculumStages)
    'vehicle-$stage': vehicleScenario(id: 'vehicle-$stage', stage: stage),
};

Map<String, GameTrainingScenario> evaluationScenarioCatalog() => {
  'guard-evaluation': guardScenario(
    id: 'guard-evaluation',
    split: TrainingSplit.test,
    heldOut: true,
  ),
  'guard-memory': guardScenario(
    id: 'guard-memory',
    split: TrainingSplit.test,
    heldOut: true,
    targetSpeed: .3,
    occluderTick: 41,
  ),
  'vehicle-evaluation': vehicleScenario(
    id: 'vehicle-evaluation',
    split: TrainingSplit.test,
    heldOut: true,
  ),
  'vehicle-recovery': vehicleScenario(
    id: 'vehicle-recovery',
    split: TrainingSplit.test,
    heldOut: true,
    stage: 'task-combinations',
  ),
  'guard-paired-left': guardScenario(
    id: 'guard-paired-left',
    split: TrainingSplit.test,
    heldOut: true,
    hiddenTargetX: -3,
    occluderTick: 0,
  ),
  'guard-paired-right': guardScenario(
    id: 'guard-paired-right',
    split: TrainingSplit.test,
    heldOut: true,
    hiddenTargetX: 3,
    occluderTick: 0,
  ),
};
