import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';

/// Small native fixture. Body observations retain A3's explicit validity mask.
GameTrainingScenario nativeBodyScenario({
  TrainingSplit split = TrainingSplit.training,
}) => GameTrainingScenario(
  id: 'native-body',
  split: split,
  maxSteps: 2000,
  create: (seed, episode) async {
    final world = PhysicsWorld(gravity: Vec3.zero);
    GameSimulation? owner;
    try {
      final body = world.createBody();
      body.addCollider(const SphereShape(.1));
      final project = CompiledGameProject(
        project: GameProject(
          id: 'native-body-fixture',
          startupLevel: 'level',
          registry: GameRegistry(),
          levels: [
            GameLevel(
              id: 'level',
              scene: GameSceneIdentity('fixture', '1'),
              entities: [GameEntityRecord(id: 'actor')],
            ),
          ],
        ),
        systemVersions: {'training.actions': 1},
      );
      final physics = PhysicsPlugin(
        world: world,
        externallyDriven: true,
        interpolate: false,
      );
      final actions = _BodyActions(body);
      final simulation = GameSimulation(
        project: project,
        seed: seed,
        physics: physics,
        systems: [actions],
        ownsWorld: true,
      );
      owner = simulation;
      simulation.step();
      final assembler = ObservationAssembler(
        registry: SensorRegistry()..register(BodySensor(maxSpeed: 1)),
        profile: SensorProfile(maxEntities: 1, maxCandidates: 1),
      );
      final host = _NativeScenario(
        simulation,
        body,
        assembler,
        episode,
        actions,
      );
      final registration = simulation.session.registerStateCodec(
        _BodyCodec(host),
      );
      host.resetBrain();
      return GameTrainingInstance(
        session: simulation.session,
        step: simulation.step,
        close: () async {
          registration.cancel();
          await host.brain.close();
          await simulation.close();
        },
        observe: host.observe,
        observationSchemaHash: assembler.spec.hash,
        actionSchemaHash: ScriptedBrain.characterActions.hash,
        actionWidth: 2,
        reward: () => actions.lastX * simulation.session.stepSeconds,
        terminal: () => body.state.pose.position.x >= 5,
        success: () => body.state.pose.position.x >= 5,
        info: () => {
          'baseline_action': host.baselineAction(),
          'accepted_action': actions.lastAction,
          'physics_position': body.state.pose.position.storage,
          'physics_backend': 'rapier',
          'renderer': null,
          'observation_schema': assembler.spec.toJson(),
        },
      );
    } catch (_) {
      if (owner != null) {
        await owner.close();
      } else if (!world.isClosed) {
        world.close();
      }
      rethrow;
    }
  },
);

final class _BodyActions extends GameSystem {
  final PhysicsBody body;
  double lastX = 0;
  List<double> lastAction = [];
  _BodyActions(this.body);
  @override
  String get id => 'training.actions';
  @override
  GamePhase get phase => GamePhase.controllers;
  @override
  void fixedUpdate(GameSession session) {
    for (final command in session.currentCommands) {
      final payload = command.payload;
      if (payload is Map && payload['action'] is List) {
        final action = payload['action'] as List;
        lastAction = [
          (action[0] as num).toDouble(),
          (action[1] as num).toDouble(),
        ];
        lastX = lastAction[0];
        body.setVelocity(Vec3(lastX, 0, lastAction[1]));
      }
    }
  }
}

final class _NativeScenario {
  final GameSimulation simulation;
  final PhysicsBody body;
  final ObservationAssembler assembler;
  final String episode;
  final _BodyActions actions;
  late ScriptedBrain brain;
  ObservationFrame? frame;
  _NativeScenario(
    this.simulation,
    this.body,
    this.assembler,
    this.episode,
    this.actions,
  );
  GameEntityHandle get actor =>
      simulation.session.entities.entities.single.handle;
  void resetBrain() {
    final identity = BrainIdentity(
      episodeId: episode,
      entity: actor,
      modelHash: 'scripted-v1',
    );
    brain = ScriptedBrain(
      identity: identity,
      entities: simulation.session.entities,
    );
    frame = null;
  }

  Map<String, Float32List> observe() {
    final snapshot = SensorSnapshot.fromSimulation(
      episodeId: episode,
      worldRevision: simulation.session.tick,
      simulation: simulation,
      bindings: {actor: body},
      colliders: {},
      currentRevision: () => simulation.session.tick,
      geometryLoaded: (_, _) => true,
    );
    frame = assembler.build(snapshot, actor);
    brain.observe(frame!);
    return {actor.id: Float32List.fromList(frame!.tensor.float32Values)};
  }

  List<double> baselineAction() {
    // This is an authored local route, not a hidden live target position.
    final decision = brain.decide(
      BrainContext(
        identity: brain.identity,
        tick: simulation.session.tick + 1,
        observation: frame,
        beliefs: brain.memory.atTick(simulation.session.tick),
        goals: [
          GameGoal(
            id: 'route',
            skill: 'follow-route',
            route: [const Vec3(1, 0, 0)],
          ),
        ],
        actionSpec: ScriptedBrain.characterActions,
      ),
    );
    for (final command in decision.actions) {
      if (command.action == 'ai.move') {
        return [
          (command.arguments['moveX'] as num).toDouble(),
          (command.arguments['moveZ'] as num).toDouble(),
        ];
      }
    }
    return [0, 0];
  }
}

final class _BodyState {
  final PhysicsPose pose;
  final Vec3 velocity;
  final List<double> action;
  _BodyState(this.pose, this.velocity, this.action);
}

final class _BodyCodec extends GameStateCodec<_BodyState> {
  final _NativeScenario host;
  _BodyCodec(this.host);
  @override
  String get id => 'training.body';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) => {
    'pose': host.body.state.pose.json,
    'velocity': host.body.state.velocity.storage,
    'action': host.actions.lastAction,
  };
  @override
  _BodyState prepare(GameSession session, Map<String, Object?> data) {
    final pose = data['pose'] as Map, velocity = data['velocity'] as List;
    final action = data['action'] as List;
    final position = pose['position'] as List,
        rotation = pose['rotation'] as List;
    if ((action.isNotEmpty && action.length != 2) ||
        action.any((v) => v is! num || !v.isFinite || v.abs() > 1) ||
        position.length != 3 ||
        rotation.length != 4 ||
        velocity.length != 3 ||
        [
          ...position,
          ...rotation,
          ...velocity,
        ].any((v) => v is! num || !v.isFinite)) {
      throw FormatException('Invalid native body state.');
    }
    return _BodyState(
      PhysicsPose(
        position: Vec3(
          (position[0] as num).toDouble(),
          (position[1] as num).toDouble(),
          (position[2] as num).toDouble(),
        ),
        rotation: Quat(
          (rotation[0] as num).toDouble(),
          (rotation[1] as num).toDouble(),
          (rotation[2] as num).toDouble(),
          (rotation[3] as num).toDouble(),
        ),
      ),
      Vec3(
        (velocity[0] as num).toDouble(),
        (velocity[1] as num).toDouble(),
        (velocity[2] as num).toDouble(),
      ),
      [for (final v in action) (v as num).toDouble()],
    );
  }

  @override
  void commit(GameSession session, _BodyState prepared) {
    host.body.teleport(prepared.pose);
    host.body.setVelocity(prepared.velocity);
    host.actions.lastAction = List.of(prepared.action);
    host.actions.lastX = prepared.action.firstOrNull ?? 0;
    host.brain.reset(
      BrainReset(
        BrainIdentity(
          episodeId: host.episode,
          entity: host.actor,
          modelHash: 'scripted-v1',
        ),
        BrainResetReason.manual,
      ),
    );
    host.frame = null;
  }
}
