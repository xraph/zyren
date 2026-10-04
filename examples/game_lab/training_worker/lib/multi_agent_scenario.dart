import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'clock_renderer.dart';

final class _MultiCommands extends GameSystem {
  late void Function(GameEntityHandle, List<double>) apply;
  @override
  String get id => 'training.multi-actions';
  @override
  GamePhase get phase => GamePhase.commands;
  @override
  void fixedUpdate(GameSession session) {
    for (final command in session.currentCommands) {
      final payload = command.payload;
      if (payload is Map && payload['action'] is List) {
        apply(command.target, [
          for (final v in payload['action'] as List) (v as num).toDouble(),
        ]);
      }
    }
  }
}

GameTrainingScenario multiAgentScenario({
  bool competitive = false,
  bool dynamic = false,
  TrainingSplit split = TrainingSplit.training,
  bool heldOut = false,
}) {
  final id =
      '${competitive ? 'competitive-pursuit' : 'cooperative-search'}${dynamic ? '-dynamic' : ''}${heldOut ? '-evaluation' : ''}';
  final contract = TrainingMultiProfiles.forTask(
    task: competitive ? 'competitive-pursuit' : 'cooperative-search',
  );
  final assembler = contract.assembler;
  final communication = contract.communication;
  final schema = contract.spec.toJson();
  final hash = contract.spec.hash;
  final decoder = contract.decoder;
  return GameTrainingScenario(
    id: id,
    split: split,
    maxSteps: 240,
    create: (seed, episode) async {
      final registry = GameRegistry();
      registerGameComponentCodecs(registry);
      registerGameLevelCodecs(registry);
      final scene = Scene(), camera = PerspectiveCamera();
      final ids = ['a', 'b', if (dynamic) 'guest'];
      final objects = <String, Object3D>{
        'ground': scene.add(Group()..position = const Vec3(0, -.5, 0)),
        'wall': scene.add(Group()..position = const Vec3(0, 1, 3)),
        'target': scene.add(
          Group()
            ..position = Vec3(
              -2 + (heldOut ? (seed % 5 - 2) * .25 : 0),
              .81,
              6,
            ),
        ),
        for (final a in ids)
          a: scene.add(
            Group()
              ..position = Vec3(
                a == 'a'
                    ? -2
                    : a == 'b'
                    ? 2
                    : 4,
                .81,
                competitive && a == 'b' ? 5 : 0,
              ),
          ),
      };
      GameComponentRecord collider(GameColliderDefinition value) =>
          GameComponentRecord('game.collider', 1, value.toJson());
      final project = CompiledGameProject(
        project: GameProject(
          id: 'multi-${competitive ? 'pursuit' : 'search'}-v1',
          startupLevel: 'arena',
          registry: registry,
          levels: [
            GameLevel(
              id: 'arena',
              scene: GameSceneIdentity('multi-arena', '1'),
              entities: [
                GameEntityRecord(
                  id: 'ground',
                  nodeId: 'ground',
                  components: [
                    collider(
                      GameColliderDefinition(
                        halfExtents: const Vec3(12, .5, 12),
                      ),
                    ),
                  ],
                ),
                GameEntityRecord(
                  id: 'wall',
                  nodeId: 'wall',
                  components: [
                    collider(
                      GameColliderDefinition(
                        halfExtents: const Vec3(.15, 1, .7),
                      ),
                    ),
                  ],
                ),
                GameEntityRecord(
                  id: 'target',
                  nodeId: 'target',
                  components: [
                    collider(
                      GameColliderDefinition(
                        shape: GameColliderShape.sphere,
                        radius: .25,
                      ),
                    ),
                  ],
                ),
                for (final a in ids)
                  GameEntityRecord(
                    id: a,
                    nodeId: a,
                    components: [
                      collider(
                        GameColliderDefinition(
                          shape: GameColliderShape.capsule,
                          motion: GameBodyMotion.kinematic,
                        ),
                      ),
                      GameComponentRecord(
                        'game.character',
                        1,
                        GameCharacterDefinition(maxSpeed: 2).toJson(),
                      ),
                    ],
                  ),
              ],
            ),
          ],
        ),
        systemVersions: {'training.multi-actions': 1},
        fixedHz: 50,
      );
      final commands = _MultiCommands();
      final runtime = GameLevelRuntime(
        project: project,
        scene: scene,
        camera: camera,
        objects: objects,
        seed: seed,
        systemFactory: (_) => [commands],
      );
      SceneEngine? engine;
      final controls = <GameEntityHandle, GameRuntimeActorControl>{};
      try {
        await runtime.initialize();
        engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          rendererFactory: () async => TrainingClockRenderer(),
          plugins: runtime.plugins,
        );
        final simulation = runtime.simulation!;
        simulation.step();
        final session = simulation.session;
        GameEntityHandle handle(String id) => session.entities.entities
            .singleWhere((e) => e.handle.id == id)
            .handle;
        final actors = {for (final a in ids) a: handle(a)};
        final target = handle('target');
        final team = GameTeam(
          id: 'search',
          episodeId: episode,
          entities: session.entities,
          maxMembers: 3,
        );
        final channel = TeamChannel(teams: [team], profile: communication);
        final active = <String>{'a', 'b'}, previousActive = <String>{};
        final captures = <int, Map<GameEntityHandle, PhysicsPose>>{};
        final remembered = <String, ({Vec3 position, int tick})>{};
        final teacher = <String, List<double>>{},
            rewards = <String, double>{},
            terminated = <String, bool>{},
            truncated = <String, bool>{};
        final previousDistance = <String, double>{};
        final applied = <String, List<double>>{};
        var delivered = 0, sent = 0, collision = false;
        Map<String, Float32List> observations = {};
        Map<String, Float32List> terminalObservations = {};
        for (final a in ids) {
          controls[actors[a]!] = runtime.acquireActorControl(actors[a]!)!;
          if (a != 'guest') {
            team.join(
              BrainIdentity(
                episodeId: episode,
                entity: actors[a]!,
                modelHash: 'training-scripted-v1',
              ),
            );
          }
        }
        commands.apply = (actor, values) {
          final legality = [
            for (final branch in decoder.spec.branches)
              List.filled(branch.choices.length, true),
          ];
          legality[4][1] = runtime.actorGrounded(actor) == true;
          legality[5][1] = false;
          final decoded =
              decoder.decode(
                PolicyAction([], values.map((v) => v.toInt()).toList()),
                legality: legality,
              ) ??
              decoder.fallback;
          controls[actor]!.applyCharacter(decoded.character!);
          applied[actor.id] = decoded.action.discrete
              .map((v) => v.toDouble())
              .toList();
        };
        void observe() {
          final tick = session.tick;
          previousActive
            ..clear()
            ..addAll(active);
          if (dynamic && tick == 6) {
            active.add('guest');
            team.join(
              BrainIdentity(
                episodeId: episode,
                entity: actors['guest']!,
                modelHash: 'training-scripted-v1',
              ),
            );
          }
          if (dynamic && tick == 11) {
            active.remove('guest');
            team.leave(actors['guest']!);
            controls[actors['guest']!]!.dispose();
          }
          final observedActors = {...active, ...previousActive};
          final bindings = {
            for (final a in observedActors)
              actors[a]!: runtime.resolveBody(actors[a]!)!,
            target: runtime.resolveBody(target)!,
          };
          final snapshot = SensorSnapshot.fromSimulation(
            episodeId: episode,
            worldRevision: tick,
            simulation: simulation,
            bindings: bindings,
            colliders: {
              for (final entry in bindings.entries)
                runtime.resolveCollider(entry.key)!.id: SensorCollider(
                  SensorMaterial.opaque,
                  entity: entry.key,
                ),
            },
            currentRevision: () => session.tick,
            geometryLoaded: (_, _) => true,
          );
          captures[tick] = {
            for (final e in bindings.entries) e.key: e.value.state.pose,
          };
          captures.removeWhere((t, _) => t < tick - 100);
          channel.capture(snapshot);
          final frames = {
            for (final a in observedActors)
              a: assembler.build(snapshot, actors[a]!),
          };
          for (final a in active) {
            channel.observe(frames[a]!);
          }
          if (!competitive && tick % 5 == 0) {
            for (final a in active) {
              final frame = frames[a]!;
              if (frame.entities.any((e) => e?.handle == target)) {
                for (final b in active.where((b) => b != a)) {
                  if (channel.send(
                    id: '$a-$b-$tick',
                    sender: actors[a]!,
                    recipient: actors[b]!,
                    target: target,
                    tick: tick,
                  )) {
                    sent++;
                  }
                }
              }
            }
          }
          final next = <String, Float32List>{};
          for (final a in observedActors) {
            final body = runtime.resolveBody(actors[a]!)!,
                pose = body.state.pose;
            for (final message
                in active.contains(a)
                    ? channel.receive(actors[a]!, tick: tick)
                    : <TeamMessage>[]) {
              final captured =
                  captures[message.observedTick]?[message.sender.entity];
              if (captured != null) {
                remembered[a] = (
                  position:
                      captured.position +
                      captured.rotation.rotate(message.position),
                  tick: message.observedTick,
                );
                delivered++;
              }
            }
            final goal = competitive ? actors[a == 'a' ? 'b' : 'a']! : target;
            final frame = frames[a]!;
            final observed = frame.entities
                .where((e) => e?.handle == goal)
                .firstOrNull;
            Vec3? permitted;
            if (observed != null) {
              permitted =
                  pose.position + pose.rotation.rotate(observed.localPosition);
            }
            final memory = remembered[a];
            if (permitted == null &&
                !competitive &&
                memory != null &&
                tick - memory.tick < 100) {
              permitted = memory.position;
            }
            final input = Float32List(assembler.spec.width + 10)
              ..setRange(0, assembler.spec.width, frame.tensor.float32Values);
            final waypoint = Vec3(2, .81, 4) - pose.position;
            input.setRange(assembler.spec.width, assembler.spec.width + 4, [
              a == 'a' ? 1 : -1,
              !competitive && a != 'a' && pose.position.z < 4
                  ? waypoint.x / 15
                  : 0,
              !competitive && a != 'a' && pose.position.z < 4
                  ? waypoint.z / 15
                  : 0,
              !competitive && a != 'a' && pose.position.z < 4 ? 1 : 0,
            ]);
            if (!competitive && memory != null && tick - memory.tick < 100) {
              final q = pose.rotation;
              final local = Quat(
                -q.x,
                -q.y,
                -q.z,
                q.w,
              ).rotate(memory.position - pose.position);
              input.setRange(assembler.spec.width + 4, input.length, [
                local.x / 15,
                local.y / 15,
                local.z / 15,
                (tick - memory.tick) / 100,
                1,
                1,
              ]);
            }
            next[a] = input;
            collision |= runtime.world!
                .overlap(
                  shape: const CapsuleShape(halfHeight: .5, radius: .3),
                  pose: pose,
                  filter: QueryFilter(excludeBody: body, excludeSensors: true),
                )
                .any(
                  (id) => id != runtime.resolveCollider(handle('ground'))!.id,
                );
            Vec3 route = permitted == null
                ? Vec3.zero
                : permitted - pose.position;
            if (!competitive && a != 'a' && pose.position.z < 4) {
              route = Vec3(2, .81, 4) - pose.position;
            }
            if (competitive && a == 'b') {
              route = permitted == null ? const Vec3(1, 0, 1) : -route;
            }
            final horizontal = Vec3(route.x, 0, route.z);
            final direction = horizontal.length < .4
                ? Vec3.zero
                : horizontal.normalized();
            teacher[a] = TrainingActions.encodeCharacter(
              CharacterIntent(moveX: direction.x, moveZ: direction.z),
            ).discrete.map((v) => v.toDouble()).toList();
            final desired = runtime.resolveBody(goal)!.state.pose.position;
            final distance = (desired - pose.position).length;
            final prior = previousDistance[a] ?? distance;
            rewards[a] =
                ((competitive && a == 'b')
                        ? distance - prior
                        : prior - distance)
                    .clamp(-1, 1);
            previousDistance[a] = distance;
          }
          final union = {...previousActive, ...active};
          final reached = competitive
              ? previousDistance['a']! < .8
              : active.every((a) => previousDistance[a]! < .8);
          rewards.removeWhere((a, _) => !union.contains(a));
          for (final a in union) {
            if (!active.contains(a)) rewards[a] = 0;
            rewards.putIfAbsent(a, () => 0);
            terminated[a] = !active.contains(a) || reached;
            truncated[a] = !terminated[a]! && tick >= 241;
          }
          observations = {for (final a in active) a: next[a]!};
          terminalObservations = {
            for (final a in previousActive.difference(active)) a: next[a]!,
          };
        }

        observe();
        return GameTrainingInstance(
          session: session,
          step: simulation.step,
          close: () async {
            for (final c in controls.values) {
              c.dispose();
            }
            try {
              await engine?.dispose();
            } finally {
              await runtime.close();
            }
          },
          actors: () => active.map((a) => actors[a]!),
          observe: () => observations,
          afterStep: () async => observe(),
          observationSchemaHash: hash,
          actionSchemaHash: decoder.spec.hash,
          actionWidth: 6,
          supportsSnapshot: false,
          acceptAction: (v) =>
              v.every((n) => n == n.roundToDouble()) &&
              decoder.spec.accepts([], v.map((n) => n.toInt()).toList()),
          actionSpace: {
            'kind': 'multi_discrete',
            'nvec': [5, 5, 5, 3, 2, 2],
          },
          reward: () => rewards.values.fold(0.0, (sum, v) => sum + v),
          terminal: () => active.every((a) => terminated[a] == true),
          success: () => active.every((a) => previousDistance[a]! < .8),
          info: () => {
            'observation_schema': schema,
            'multi_profile': contract.toJson(),
            'action_schema': decoder.spec.toJson(),
            'observation_width': assembler.spec.width + 10,
            'per_agent_legality': {
              for (final a in active)
                a: [
                  for (
                    var branch = 0;
                    branch < decoder.spec.branches.length;
                    branch++
                  )
                    [
                      for (
                        var choice = 0;
                        choice < decoder.spec.branches[branch].choices.length;
                        choice++
                      )
                        branch == 4 && choice == 1
                            ? runtime.actorGrounded(actors[a]!) == true
                            : branch == 5 && choice == 1
                            ? false
                            : true,
                    ],
                ],
            },
            'terminal_observations': {
              for (final entry in terminalObservations.entries)
                entry.key: entry.value.toList(),
            },
            'applied_actions': applied,
            'per_agent_rewards': {
              for (final a in {...previousActive, ...active}) a: rewards[a],
            },
            'per_agent_terminated': {
              for (final a in {...previousActive, ...active}) a: terminated[a],
            },
            'per_agent_truncated': {
              for (final a in {...previousActive, ...active}) a: truncated[a],
            },
            'training_only': {
              'teacher_actions': teacher,
              'distances': previousDistance,
              'state': [
                for (final a in actors.values)
                  ...runtime.resolveBody(a)!.state.pose.position.storage,
              ],
            },
            'team_messages_sent': sent,
            'team_messages_delivered': delivered,
            'team_pending': channel.pendingCount,
            'team_profile': communication.toJson(),
            'physics_backend': 'rapier',
            'renderer': null,
            'collision': collision,
            'scenario_spec': {
              'schema_version': 1,
              'id': id,
              'partition': split == TrainingSplit.training
                  ? 'train'
                  : split.name,
              'game_build_hash': session.project.buildId,
              'observation_schema_hash': hash,
              'action_schema_hash': decoder.spec.hash,
              'callback_id': competitive
                  ? 'competitive.pursuit'
                  : 'cooperative.search',
              'reward_terms': [
                {'id': 'task.progress', 'cap': 1.0},
              ],
              'seed': seed,
              'max_steps': 240,
              'control_cadence': 1,
              'latency_ticks': 1,
              'assets': [],
              'settings': {
                'map': 'native-multi-arena-v1',
                'fixed_hz': 50,
                'competitive': competitive,
                'dynamic': dynamic,
                'message_profile': communication.toJson(),
              },
            },
          },
        );
      } catch (_) {
        for (final c in controls.values) {
          c.dispose();
        }
        try {
          await engine?.dispose();
        } finally {
          await runtime.close();
        }
        rethrow;
      }
    },
  );
}

Map<String, GameTrainingScenario> multiAgentScenarioCatalog({
  bool evaluation = false,
}) => {
  for (final competitive in [false, true])
    for (final dynamic in [false, true])
      '${competitive ? 'competitive-pursuit' : 'cooperative-search'}${dynamic ? '-dynamic' : ''}${evaluation ? '-evaluation' : ''}':
          multiAgentScenario(
            competitive: competitive,
            dynamic: dynamic,
            heldOut: evaluation,
            split: evaluation ? TrainingSplit.test : TrainingSplit.training,
          ),
};
