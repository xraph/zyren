part of '../../gameplay.dart';

final class _CheckpointSelection {
  final GameEntityHandle checkpoint, spawn;
  const _CheckpointSelection(this.checkpoint, this.spawn);
}

void _validateCheckpointRecipes(Map<String, GameEntityRecord> records) {
  for (final record in records.values) {
    final checkpoint = record.components
        .where((c) => c.type == 'game.checkpoint')
        .firstOrNull;
    if (checkpoint == null) continue;
    final spawn = records[checkpoint.data['spawn']];
    if (record.nodeId == null ||
        spawn?.nodeId == null ||
        !spawn!.components.any((c) => c.type == 'game.spawn')) {
      throw StateError(
        'Checkpoints require an authored checkpoint node and spawn node.',
      );
    }
  }
}

extension _GameCheckpoints on GameLevelGameplay {
  GameEntityHandle? _liveHandle(String id) => _session?.entities.entities
      .where((e) => e.handle.id == id)
      .firstOrNull
      ?.handle;
  bool _selectionLive(GameEntityHandle actor, _CheckpointSelection selection) =>
      play.isEntityActive(actor) &&
      play.isEntityActive(selection.checkpoint) &&
      play.isEntityActive(selection.spawn) &&
      play
              .entityDefinition(selection.checkpoint.id)
              ?.components
              .where((c) => c.type == 'game.checkpoint')
              .firstOrNull
              ?.data['spawn'] ==
          selection.spawn.id;
  void _pruneCheckpoints() => _checkpoints.removeWhere(
    (actor, selection) => !_selectionLive(actor, selection),
  );
  void _selectCheckpoints(GameSession session) {
    _pruneCheckpoints();
    final entities = session.entities.entities,
        handles = {for (final e in entities) e.handle.id: e.handle};
    final probes =
        <
          ({
            GameEntityHandle checkpoint,
            GameEntityHandle spawn,
            Vec3 center,
            double radius,
          })
        >[];
    for (final entity in entities) {
      if (!play.isEntityActive(entity.handle)) continue;
      final component = entity.components
          .where((c) => c.type == 'game.checkpoint')
          .firstOrNull;
      if (component == null) continue;
      final spawn = handles[component.data['spawn']],
          center = _position(entity.handle);
      if (spawn == null || !play.isEntityActive(spawn) || center == null) {
        continue;
      }
      probes.add((
        checkpoint: entity.handle,
        spawn: spawn,
        center: center,
        radius: (component.data['radius'] as num).toDouble(),
      ));
    }
    if (probes.isEmpty) return;
    final poses = {
      for (final body in play.world!.states) body.id: body.pose.position,
    };
    Vec3? actorPosition(GameEntityHandle actor) {
      final physical = actor == play.inputActor
          ? play.controlledActor ?? actor
          : actor;
      final body = play.resolveBody(physical);
      return body == null ? _position(actor) : poses[body.id];
    }

    for (final entity in entities) {
      if (!play.isEntityActive(entity.handle) ||
          !entity.components.any(
            (c) => c.type == 'game.character' || c.type == 'game.vehicle',
          )) {
        continue;
      }
      final position = actorPosition(entity.handle);
      if (position == null) continue;
      var nearest = double.infinity;
      _CheckpointSelection? chosen;
      for (final probe in probes) {
        final distance = position.distanceTo(probe.center);
        if (distance > probe.radius) continue;
        if (distance < nearest ||
            (distance == nearest &&
                probe.checkpoint.id.compareTo(chosen!.checkpoint.id) < 0)) {
          nearest = distance;
          chosen = _CheckpointSelection(probe.checkpoint, probe.spawn);
        }
      }
      if (chosen != null) _checkpoints[entity.handle] = chosen;
    }
  }
}

final class _CheckpointCodec extends GameStateCodec<Map<String, Object?>> {
  final GameLevelGameplay owner;
  _CheckpointCodec(this.owner);
  @override
  String get id => 'game.native-checkpoints';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) => {
    'entities': session.entities.entities.map((e) => e.handle.id).toList(),
    'selections': {
      for (final e in owner._checkpoints.entries.where(
        (e) => owner._selectionLive(e.key, e.value),
      ))
        e.key.id: [e.value.checkpoint.id, e.value.spawn.id],
    },
  };
  @override
  Map<String, Object?> prepare(GameSession session, Map<String, Object?> data) {
    if (data.length != 2 ||
        data['entities'] is! List ||
        data['selections'] is! Map) {
      throw const FormatException('Invalid checkpoint selection state.');
    }
    final ids = List<String>.from(data['entities'] as List),
        selections = Map<String, Object?>.from(data['selections'] as Map);
    if (ids.length > session.entities.limits.maxEntities ||
        ids.toSet().length != ids.length ||
        selections.length > ids.length ||
        !ids.toSet().containsAll(selections.keys)) {
      throw const FormatException('Invalid checkpoint selection identities.');
    }
    final records = <String, GameEntityRecord>{};
    for (final id in ids) {
      final record = owner.play.entityDefinition(id);
      if (record == null) {
        throw const FormatException('Unknown checkpoint recipe.');
      }
      records[id] = record;
    }
    _validateCheckpointRecipes(records);
    final prepared = <String, Object?>{};
    for (final e in selections.entries) {
      if (e.value is! List || (e.value as List).length != 2) {
        throw const FormatException('Invalid selected checkpoint.');
      }
      final pair = List<String>.from(e.value as List),
          checkpoint = records[pair[0]],
          spawn = records[pair[1]],
          actor = records[e.key]!;
      if (!actor.components.any(
            (c) => c.type == 'game.character' || c.type == 'game.vehicle',
          ) ||
          checkpoint?.components
                  .where((c) => c.type == 'game.checkpoint')
                  .firstOrNull
                  ?.data['spawn'] !=
              pair[1] ||
          spawn?.components.any((c) => c.type == 'game.spawn') != true) {
        throw const FormatException(
          'Saved selection does not match checkpoint and spawn recipes.',
        );
      }
      prepared[e.key] = List<String>.unmodifiable(pair);
    }
    return {
      'entities': List<String>.unmodifiable(ids),
      'selections': Map<String, Object?>.unmodifiable(prepared),
    };
  }

  @override
  void commit(GameSession session, Map<String, Object?> prepared) {
    final ids = (prepared['entities'] as List).cast<String>().toSet(),
        current = session.entities.entities.map((e) => e.handle.id).toSet();
    if (ids.length != current.length || !ids.containsAll(current)) {
      throw const FormatException(
        'Checkpoint selections differ from restored entity topology.',
      );
    }
    final selections = <GameEntityHandle, _CheckpointSelection>{};
    for (final e in (prepared['selections'] as Map<String, Object?>).entries) {
      final pair = (e.value as List).cast<String>();
      selections[owner._liveHandle(e.key)!] = _CheckpointSelection(
        owner._liveHandle(pair[0])!,
        owner._liveHandle(pair[1])!,
      );
    }
    owner._checkpoints
      ..clear()
      ..addAll(selections);
  }
}
