/// Native interaction bindings for authored gameplay in a compiled level.
library;

import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game/authored.dart';
import 'zyren_game_native.dart';
import 'package:zyren_interaction/zyren_interaction.dart';
import 'runtime.dart';

class GameLevelGameplay extends GameSystem implements GameAuthoredWorld {
  final GameLevelRuntime play;
  final GameRuleLibrary library;
  late final GameAuthoredGameplay authored = GameAuthoredGameplay(
    library: library,
    world: this,
  );
  SceneInteractionRouter? _router;
  final _queries = <GameEntityHandle, InteractionQuery>{};
  final _nodes = <String, String?>{};
  GameSession? _session;
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
    final scene = play;
    _nodes.addAll({
      for (final entity
          in session.project.levels
              .singleWhere((l) => l.id == session.levelId)
              .entities)
        entity.id: entity.nodeId,
    });
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
    authored.start(session);
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
    authored.fixedUpdate(session);
  }

  @override
  void pause(GameSession session) => authored.pause(session);
  @override
  void dispose(GameSession session) {
    for (final query in _queries.values) {
      query.close();
    }
    _queries.clear();
    _nodes.clear();
    _router?.dispose();
    _router = null;
    authored.dispose(session);
    _session = null;
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
