import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/training.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_physics/zyren_physics.dart';
import 'clock_renderer.dart';
import 'multi_agent_outcome.dart';

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
      '${competitive ? 'competitive-pursuit' : 'cooperative-search'}${dynamic ? '-dynamic' : ''}${heldOut
          ? split == TrainingSplit.validation
                ? '-validation'
                : '-evaluation'
          : ''}';
  const horizon = 400;
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
    maxSteps: horizon,
    create: (seed, episode) async {
      final registry = GameRegistry();
      registerGameComponentCodecs(registry);
      registerGameLevelCodecs(registry);
      final scene = Scene(), camera = PerspectiveCamera();
      final ids = ['a', 'b', if (dynamic) 'guest'];
      final objects = <String, Object3D>{
        'ground': scene.add(Group()..position = const Vec3(0, -.5, 0)),
        'wall': scene.add(Group()..position = Vec3(competitive ? 20 : 0, 1, 3)),
        'west': scene.add(Group()..position = const Vec3(-8.5, 1, 0)),
        'east': scene.add(Group()..position = const Vec3(8.5, 1, 0)),
        'south': scene.add(Group()..position = const Vec3(0, 1, -9.5)),
        'north': scene.add(Group()..position = const Vec3(0, 1, 9.5)),
        'target': scene.add(
          Group()
            ..position = Vec3(
              -2 + (seed % 5 - 2) * (heldOut ? .25 : .1),
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
                competitive && a == 'b' ? 5 + (seed % 3 - 1) * .15 : 0,
              ),
          ),
      };
      GameComponentRecord collider(GameColliderDefinition value) =>
          GameComponentRecord('game.collider', 1, value.toJson());
      final project = CompiledGameProject(
        project: GameProject(
          id: 'multi-${competitive ? 'pursuit' : 'search'}-v2',
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
                for (final boundary in ['west', 'east', 'south', 'north'])
                  GameEntityRecord(
                    id: boundary,
                    nodeId: boundary,
                    components: [
                      collider(
                        GameColliderDefinition(
                          halfExtents: boundary == 'west' || boundary == 'east'
                              ? const Vec3(.5, 1, 9.5)
                              : const Vec3(8.5, 1, .5),
                        ),
                      ),
                    ],
                  ),
                GameEntityRecord(
                  id: 'target',
                  nodeId: 'target',
                  components: [
                    if (!competitive)
                      collider(
                        GameColliderDefinition(
                          shape: GameColliderShape.sphere,
                          radius: .25,
                          sensor: true,
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
                        GameCharacterDefinition(
                          maxSpeed: competitive && a == 'b' ? 1.5 : 2,
                        ).toJson(),
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
        final ownSightings = <String, ({Vec3 position, int tick})>{};
        final teacher = <String, List<double>>{},
            rewards = <String, double>{},
            terminated = <String, bool>{},
            truncated = <String, bool>{};
        final previousDistance = <String, double>{};
        final applied = <String, List<double>>{};
        var delivered = 0, sent = 0, collision = false;
        var legalArena = true, captured = false;
        MultiTaskOutcome? outcome;
        final routeIndex = <String, int>{};
        final routes = <String, List<Vec3>>{
          'a': [],
          'b': competitive
              ? [
                  const Vec3(6, .81, 5),
                  const Vec3(6, .81, -6),
                  const Vec3(-6, .81, -6),
                  const Vec3(-6, .81, 6),
                ]
              : [const Vec3(2, .81, 4)],
          if (dynamic) 'guest': [const Vec3(4, .81, 4)],
        };
        final solidIds = {
          for (final id in ['wall', 'west', 'east', 'south', 'north'])
            runtime.resolveCollider(handle(id))!.id,
        };
        Map<String, Float32List> observations = {};
        Map<String, Float32List> terminalObservations = {};
        for (final a in ids) {
          if (a == 'guest') {
            runtime.setEntityActive(actors[a]!, false);
          } else {
            controls[actors[a]!] = runtime.acquireActorControl(actors[a]!)!;
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
            runtime.setEntityActive(actors['guest']!, true);
            controls[actors['guest']!] = runtime.acquireActorControl(
              actors['guest']!,
            )!;
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
            controls.remove(actors['guest']!)!.dispose();
            runtime.setEntityActive(actors['guest']!, false);
          }
          final observedActors = {...active, ...previousActive};
          final bindings = {
            for (final a in observedActors)
              actors[a]!: runtime.resolveBody(actors[a]!)!,
            if (!competitive) target: runtime.resolveBody(target)!,
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
          if (!competitive && tick % contract.messageCadenceTicks == 0) {
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
              ownSightings[a] = (position: permitted, tick: tick);
            }
            final history = ownSightings[a];
            if (competitive &&
                permitted == null &&
                history != null &&
                tick - history.tick <= 100) {
              permitted = history.position;
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
            final actorRoute = routes[a]!;
            var cursor = routeIndex[a] ?? 0;
            if (cursor < actorRoute.length &&
                (actorRoute[cursor] - pose.position).length < .5) {
              cursor++;
              if (competitive && a == 'b') cursor %= actorRoute.length;
              routeIndex[a] = cursor;
            }
            final waypoint = cursor < actorRoute.length
                ? actorRoute[cursor] - pose.position
                : Vec3.zero;
            input.setRange(assembler.spec.width, assembler.spec.width + 4, [
              a == 'a' ? 1 : -1,
              waypoint.x / 15,
              waypoint.z / 15,
              cursor < actorRoute.length ? 1 : 0,
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
            collision |= runtime
                .actorContacts(actors[a]!)
                .any(
                  (contact) =>
                      solidIds.contains(contact.collider) &&
                      contact.normal.y.abs() < .5,
                );
            // Capture proximity is legal. Actual capsule penetration is not.
            collision |= runtime.world!
                .overlap(
                  shape: const CapsuleShape(halfHeight: .5, radius: .3),
                  pose: pose,
                  filter: QueryFilter(excludeBody: body, excludeSensors: true),
                )
                .any(
                  (id) => id != runtime.resolveCollider(handle('ground'))!.id,
                );
            legalArena &=
                pose.position.x.abs() <= 8 &&
                pose.position.z.abs() <= 9 &&
                pose.position.y > 0 &&
                pose.position.y < 3;
            Vec3 route = cursor < actorRoute.length
                ? waypoint
                : permitted == null
                ? Vec3.zero
                : permitted - pose.position;
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
          captured = competitive && previousDistance['a']! < .8;
          outcome = competitive
              ? MultiTaskOutcome.competitive(
                  captured: captured,
                  timedOut: tick >= horizon + 1,
                  legal: legalArena,
                )
              : MultiTaskOutcome.cooperative(
                  actors: active.toList(),
                  reached: {
                    for (final a in active)
                      if (previousDistance[a]! < .8) a,
                  },
                  timedOut: tick >= horizon + 1,
                  legal: legalArena,
                );
          rewards.removeWhere((a, _) => !union.contains(a));
          for (final a in union) {
            if (!active.contains(a)) rewards[a] = 0;
            rewards.putIfAbsent(a, () => 0);
            terminated[a] = !active.contains(a) || outcome!.ended;
            truncated[a] = false;
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
          success: () =>
              outcome?.legal == true && outcome?.results['a'] == 'win',
          info: () => {
            'per_agent_results': outcome?.results,
            'legal_arena': legalArena,
            'native_active_actor_ids': [
              for (final id in ids)
                if (runtime.isEntityActive(actors[id]!)) id,
            ],
            'task_capture': captured,
            'task_roles': competitive
                ? {'a': 'pursuer', 'b': 'evader'}
                : {
                    'a': 'scout',
                    'b': 'searcher',
                    if (dynamic) 'guest': 'searcher',
                  },
            'authored_routes': {
              for (final e in routes.entries)
                e.key: [for (final v in e.value) v.storage],
            },
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
              'max_steps': horizon,
              'control_cadence': 1,
              'latency_ticks': 1,
              'assets': [],
              'settings': {
                'map': competitive
                    ? 'native-open-pursuit-v2'
                    : 'native-occluded-search-v2',
                'legal_bounds': [8, 9],
                'capture_radius': .8,
                'pursuer_speed': 2,
                'evader_speed': competitive ? 1.5 : 2,
                'message_cadence': 5,
                'message_ttl': 100,
                'fixed_hz': 50,
                'held_out_layout': heldOut,
                'layout_generator': heldOut
                    ? split == TrainingSplit.validation
                          ? 'dev-lanes-v2'
                          : 'test-lanes-v2'
                    : 'train-lanes-v2',
                'teacher_memory_ticks': 100,
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
  bool validation = false,
}) {
  if (evaluation && validation) throw ArgumentError('Choose one multi split.');
  return {
    for (final competitive in [false, true])
      for (final dynamic in [false, true])
        '${competitive ? 'competitive-pursuit' : 'cooperative-search'}${dynamic ? '-dynamic' : ''}${evaluation
            ? '-evaluation'
            : validation
            ? '-validation'
            : ''}': multiAgentScenario(
          competitive: competitive,
          dynamic: dynamic,
          heldOut: evaluation || validation,
          split: evaluation
              ? TrainingSplit.test
              : validation
              ? TrainingSplit.validation
              : TrainingSplit.training,
        ),
  };
}
