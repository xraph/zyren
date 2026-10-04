/// Native interaction bindings for authored gameplay in a compiled level.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game/authored.dart';
import 'zyren_game_native.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'runtime.dart';
import 'package:zyren_physics/zyren_physics.dart';

part 'src/gameplay/checkpoints.dart';

class GameLevelGameplay extends GameSystem
    implements GameAuthoredWorld, GameCheckpointFacts {
  final GameLevelRuntime play;
  final GameRuleLibrary library;
  late final GameAuthoredGameplay authored = GameAuthoredGameplay(
    library: library,
    world: this,
    entityDefinition: play.entityDefinition,
  );
  SceneInteractionRouter? _router;
  Registration? _restored, _topology, _spawnValidator;
  final _queries = <GameEntityHandle, InteractionQuery>{};
  final _nodes = <String, String?>{};
  GameSession? _session;
  GameEventSubscription? _checkpointCodec;
  final _checkpoints = <GameEntityHandle, _CheckpointSelection>{};
  GameLevelGameplay(this.play, this.library);
  @override
  String get id => 'game.play-gameplay';
  @override
  GamePhase get phase => GamePhase.rules;
  @override
  Set<String> get dependencies => {'game.play-setup'};
  @override
  void start(GameSession session) {
    _session = session;
    _validateSpawn(const []);
    authored.start(session);
    _checkpointCodec = session.registerStateCodec(_CheckpointCodec(this));
    _bindQueries(session);
    _restored = play.listenRestored(() {
      _closeQueries();
      _bindQueries(session);
    });
    _spawnValidator = play.registerSpawnValidator(_validateSpawn);
    _topology = play.listenTopology((_) {
      authored.reconcile();
      _pruneCheckpoints();
      _closeQueries();
      _bindQueries(session);
    });
  }

  void _validateSpawn(List<GameEntityRecord> added) {
    final session = _session;
    if (session == null) throw StateError('Gameplay is unavailable.');
    final records = {
      for (final e in session.entities.entities)
        e.handle.id: play.entityDefinition(e.handle.id)!,
      for (final e in added) e.id: e,
    };
    _validateCheckpointRecipes(records);
    final ids = <String>{}, targets = <String>{};
    for (final entity in records.values) {
      for (final component in entity.components.where(
        (c) => c.type == 'game.interaction',
      )) {
        final definition = GameInteractionDefinition.fromJson(component.data);
        final target = records[definition.target ?? entity.id];
        if (target == null ||
            target.nodeId == null ||
            !target.components.any((c) => c.type == 'game.collider') ||
            !ids.add(definition.id) ||
            !targets.add(target.id)) {
          throw StateError(
            'Native interactions require unique IDs and collider targets.',
          );
        }
      }
    }
    if (ids.length > 1024) {
      throw StateError('Native interaction capacity exceeded.');
    }
  }

  void _bindQueries(GameSession session) {
    _nodes
      ..clear()
      ..addAll({
        for (final entity in session.entities.entities)
          entity.handle.id: play.entityDefinition(entity.handle.id)?.nodeId,
      });
    final scene = play;
    final router = _router = SceneInteractionRouter(
      scene: scene.scene,
      camera: () => scene.camera,
      viewport: () => const ViewportMetrics(0, 0),
    );
    final entities = {
      for (final entity in session.entities.entities) entity.handle.id: entity,
    };
    for (final entity in entities.values) {
      for (final record in entity.components.where(
        (c) => c.type == 'game.interaction',
      )) {
        final definition = GameInteractionDefinition.fromJson(record.data);
        final target = entities[definition.target ?? entity.handle.id];
        final body = target == null ? null : play.resolveBody(target.handle);
        final object = scene.objects[_nodes[target?.handle.id]];
        if (target == null || body == null || object == null) {
          throw StateError(
            'Interactive entities require a live collider and scene node.',
          );
        }
        if (_queries.containsKey(target.handle)) {
          throw StateError('One interaction profile per target is supported.');
        }
        final query = InteractionQuery.fromDefinition(
          session: session,
          world: play.world!,
          router: router,
          resolveBody: (actor) => play.resolveBody(
            actor == play.inputActor ? play.controlledActor ?? actor : actor,
          ),
          definition: definition,
        );
        _queries[target.handle] = query;
        query.register(
          target: target.handle,
          object: object,
          body: body,
          id: definition.id,
          label: definition.label,
          onExecute: (actor) => authored.interact(actor, definition.id),
        );
      }
    }
  }

  List<GameInteractionCandidate> available(GameEntityHandle actor) {
    final result = [
      for (final query in _queries.values) ...query.available(actor),
    ];
    result.sort(
      (a, b) => a.distance == b.distance
          ? a.id.compareTo(b.id)
          : a.distance.compareTo(b.distance),
    );
    return List.unmodifiable(result.take(16));
  }

  bool interact(GameEntityHandle actor, String id) {
    final candidate = available(actor).where((c) => c.id == id).firstOrNull;
    return candidate != null &&
        _queries[candidate.target]!.execute(actor, candidate);
  }

  @override
  bool inReach(GameEntityHandle actor, GameEntityHandle target) =>
      _queries[target]?.available(actor).any((c) => c.target == target) ??
      false;
  Vec3? _position(GameEntityHandle actor) {
    final session = _session;
    if (session == null || !session.entities.isAlive(actor)) return null;
    final handle = actor == play.inputActor
        ? play.controlledActor ?? actor
        : actor;
    final body = play.resolveBody(handle);
    if (body != null) return body.state.pose.position;
    final object = play.objects[_nodes[handle.id]];
    return object == null
        ? null
        : Vec3.fromVectorMath(
            object.worldMatrix.toVectorMath().getTranslation(),
          );
  }

  @override
  bool within(GameEntityHandle actor, String target, double distance) {
    if (!distance.isFinite || distance <= 0 || distance > 1000) return false;
    final handle = _session?.entities.entities
        .where((e) => e.handle.id == target)
        .firstOrNull
        ?.handle;
    final from = _position(actor),
        to = handle == null ? null : _position(handle);
    return from != null && to != null && from.distanceTo(to) <= distance;
  }

  @override
  bool controlling(GameEntityHandle actor, String target) =>
      actor == play.inputActor && play.controlledActor?.id == target;
  @override
  bool possess(GameEntityHandle actor, GameEntityHandle target) =>
      actor == play.inputActor && play.controlEntity(target);
  @override
  bool setActive(GameEntityHandle actor, GameEntityHandle target, bool active) {
    if (_session?.entities.isAlive(actor) != true) return false;
    play.setEntityActive(target, active);
    return true;
  }

  /// The last live checkpoint reached within its authored radius.
  GameEntityHandle? selectedCheckpoint(GameEntityHandle actor) {
    final selection = _checkpoints[actor];
    return selection != null && _selectionLive(actor, selection)
        ? selection.checkpoint
        : null;
  }

  GameEntityHandle? selectedSpawn(GameEntityHandle actor) {
    final selection = _checkpoints[actor];
    return selection != null && _selectionLive(actor, selection)
        ? selection.spawn
        : null;
  }

  @override
  bool checkpointActive(GameEntityHandle actor, String checkpoint) =>
      selectedCheckpoint(actor)?.id == checkpoint;

  /// Respawn is explicit. No death condition or fall threshold is inferred.
  @override
  bool respawnActor(GameEntityHandle actor) {
    final selection = _checkpoints[actor];
    if (selection == null || !_selectionLive(actor, selection)) return false;
    final spawn = play.objects[_nodes[selection.spawn.id]];
    if (spawn == null) return false;
    var rotation = Quat.identity;
    for (Object3D? node = spawn; node != null; node = node.parent) {
      if (node.scale.x <= 0 || node.scale.y <= 0 || node.scale.z <= 0) {
        return false;
      }
      rotation = node.quaternion * rotation;
    }
    final pose = PhysicsPose(
      position: Vec3.fromVectorMath(
        spawn.worldMatrix.toVectorMath().getTranslation(),
      ),
      rotation: rotation,
    );
    if (!play.respawnCharacterAt(actor, pose)) return false;
    authored.cancelActorWork(actor);
    return true;
  }

  @override
  void fixedUpdate(GameSession session) {
    final actor = play.inputActor, input = play.actions;
    if (actor != null &&
        input != null &&
        input.inputMap.actions['interact']?.button == true &&
        input.takePressed('interact')) {
      if (play.controlledActor != actor) {
        play.controlEntity(actor);
      } else {
        final candidate = available(actor).firstOrNull;
        if (candidate != null) {
          _queries[candidate.target]!.execute(actor, candidate);
        }
      }
    }
    _selectCheckpoints(session);
    authored.fixedUpdate(session);
  }

  @override
  void pause(GameSession session) => authored.pause(session);
  @override
  void dispose(GameSession session) {
    _checkpointCodec?.cancel();
    _checkpointCodec = null;
    _checkpoints.clear();
    _restored?.dispose();
    _topology?.dispose();
    _spawnValidator?.dispose();
    _restored = _topology = _spawnValidator = null;
    _closeQueries();
    _nodes.clear();
    authored.dispose(session);
    _session = null;
  }

  void _closeQueries() {
    for (final query in _queries.values) {
      query.close();
    }
    _queries.clear();
    _router?.dispose();
    _router = null;
  }
}

/// Journal consumers run first. The host drains once per completed game tick.
final class GameEventJournal extends GameSystem {
  List<GameEvent<Object>> latest = const [];
  @override
  String get id => 'game.play-journal';
  @override
  GamePhase get phase => GamePhase.diagnostics;
  @override
  void fixedUpdate(GameSession session) {
    latest = session.events.drain();
  }

  @override
  void dispose(GameSession session) {
    latest = const [];
  }
}
