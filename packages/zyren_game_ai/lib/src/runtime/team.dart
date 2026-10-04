part of '../../runtime.dart';

bool _matchesMultiArtifact(
  GameAiAuthoringDefinition definition,
  GameRuntimePolicy? policy,
) {
  final profile = definition.multiProfile;
  if (profile == null) return true;
  final artifact = policy?._artifact;
  return artifact != null &&
      artifact.family == definition.artifactFamily &&
      artifact.multiProfile?.configurationHash == profile.configurationHash;
}

Map<String, Object?> _teamDefinition(GameAiAuthoringDefinition definition) => {
  'task': definition.multiTask,
  'team': definition.teamId,
  'role': definition.multiRole,
  'goal': definition.goalEntityId,
  'route': [for (final p in definition.authoredRoute) p.storage],
  'profileHash': definition.multiProfile?.configurationHash,
};

bool _sameTeamDefinition(Object? data, GameAiAuthoringDefinition definition) {
  if (data is! Map || data.length != 6) return false;
  final expected = _teamDefinition(definition);
  return expected.entries.every(
    (e) => e.key == 'route'
        ? jsonEncode(data[e.key]) == jsonEncode(e.value)
        : data[e.key] == e.value,
  );
}

/// Admit the registered training topology before model or team owners are opened.
void _validateTeamRecords(
  Iterable<GameEntityRecord> records, {
  required int fixedHz,
}) {
  final byId = {for (final record in records) record.id: record};
  final groups = <String, List<GameAiAuthoringDefinition>>{};
  var count = 0;
  for (final record in byId.values) {
    final ai = record.components.where((c) => c.type == 'game.ai').firstOrNull;
    if (ai == null) continue;
    final definition = GameAiAuthoringDefinition(ai.data);
    final profile = definition.multiProfile;
    if (profile == null) continue;
    if (fixedHz != profile.fixedHz) {
      throw StateError('Multi tasks require their registered 50 Hz clock.');
    }
    if (++count > 64) {
      throw StateError('Team observation admission is bounded to 64 actors.');
    }
    if (definition.multiRole == 'pursuer' &&
        definition.authoredRoute.isNotEmpty) {
      throw StateError('The registered pursuer profile has no authored route.');
    }
    final goal = definition.goalEntityId;
    if (goal != null &&
        (!byId.containsKey(goal) ||
            goal == record.id ||
            !byId[goal]!.components.any(
              (c) => c.type == 'game.collider' || c.type == 'game.character',
            ))) {
      throw StateError(
        'A cooperative goal needs an authored native body binding.',
      );
    }
    (groups[definition.teamId!] ??= []).add(definition);
  }
  if (groups.length > 8) {
    throw StateError('At most eight teams can share a runtime.');
  }
  for (final members in groups.values) {
    final profile = members.first.multiProfile!;
    if (members.any(
      (m) =>
          m.multiTask != profile.task ||
          m.goalEntityId != members.first.goalEntityId,
    )) {
      throw StateError('A team must share one task and authored goal.');
    }
    final positive = members.where((m) => m.registeredRole == 1).length;
    final negative = members.length - positive;
    if (positive != 1 ||
        negative < 1 ||
        negative > (profile.task == 'cooperative-search' ? 2 : 1)) {
      throw StateError('Team cardinality differs from the registered task.');
    }
    final learned = members
        .where((m) => m.brain != 'scripted')
        .map((m) => m.modelHash)
        .toSet();
    if (learned.length > 1) {
      throw StateError('Registered team members share one model identity.');
    }
  }
}

final class _RuntimeTeams {
  final GameLevelAi owner;
  final _teams = <String, GameTeam>{};
  final _channels = <String, TeamChannel>{};
  final _poses = <int, Map<GameEntityHandle, PhysicsPose>>{};
  _RuntimeTeams(this.owner) {
    sync();
  }
  int get pendingCount =>
      _channels.values.fold(0, (n, c) => n + c.pendingCount);

  void sync() {
    final actors = owner._actors.values.where((a) => a.multi != null).toList();
    for (final actor in actors) {
      final goalId = actor.definition.goalEntityId;
      if (goalId == null) continue;
      final fresh = owner._session!.entities.entities
          .where((e) => e.handle.id == goalId)
          .firstOrNull
          ?.handle;
      if (fresh != null && actor.multi!.goal != fresh) {
        actor.multi = GameMultiObservationAdapter(
          identity: actor.identity,
          profile: actor.definition.multiProfile!,
          role: actor.definition.multiRole!,
          goal: fresh,
          authoredRoute: actor.definition.authoredRoute,
        );
        actor.frame = null;
        actor.multiObservationPose = null;
        actor.policy?.invalidatePending();
        actor.scripted.reset(
          BrainReset(actor.identity, BrainResetReason.manual),
        );
      }
    }
    final current = actors.map((a) => a.identity.entity).toSet();
    for (final team in _teams.values) {
      for (final member in team.members.toList()) {
        if (!current.contains(member.entity)) team.leave(member.entity);
      }
    }
    for (final actor in actors) {
      final id = actor.definition.teamId!;
      final team = _teams.putIfAbsent(
        id,
        () => GameTeam(
          id: id,
          episodeId: owner._group!.episodeId,
          entities: owner._session!.entities,
          maxMembers: 3,
        ),
      );
      if (!team.contains(actor.identity.entity)) team.join(actor.identity);
    }
    // Keep membership epochs for surviving teams. A topology change cancels all
    // delayed deliveries, including messages addressed to a retired generation.
    clear();
    for (final team in _teams.values) {
      if (team.members.isEmpty || _channels.containsKey(team.id)) continue;
      final actor = actors.firstWhere((a) => a.definition.teamId == team.id);
      _channels[team.id] = TeamChannel(
        teams: [team],
        profile: actor.definition.multiProfile!.communication,
      );
    }
    // Retained team IDs keep their deduplication ledger and membership epochs.
    if (_teams.length > 8) {
      throw StateError('Team catalog exceeded its admission bound.');
    }
  }

  List<GameGoal> goals(_RuntimeBrain actor) {
    final frame = actor.frame, captured = actor.multiObservationPose;
    final body = owner.runtime().resolveBody(actor.identity.entity);
    if (frame == null || captured == null || body == null) return const [];
    final current = body.state.pose.position, definition = actor.definition;
    final cursor = actor.multi!.routeIndex;
    Vec3 displacement = Vec3.zero;
    if (cursor < definition.authoredRoute.length) {
      displacement = definition.authoredRoute[cursor] - current;
    } else {
      final target =
          actor.multi!.goal ??
          owner._actors.values
              .where(
                (a) =>
                    a.definition.teamId == definition.teamId &&
                    a.definition.multiRole != definition.multiRole,
              )
              .firstOrNull
              ?.identity
              .entity;
      final seen = frame.entities.where((e) => e?.handle == target).firstOrNull;
      if (seen != null) {
        displacement =
            captured.position +
            captured.rotation.rotate(seen.localPosition) -
            current;
      } else {
        final values = frame.tensor.float32Values, start = values.length - 6;
        if (values[start + 4] == 1 && values[start + 5] == 1) {
          displacement =
              captured.position +
              captured.rotation.rotate(
                Vec3(
                  values[start] * 15,
                  values[start + 1] * 15,
                  values[start + 2] * 15,
                ),
              ) -
              current;
        }
      }
    }
    return [
      GameGoal(id: 'team-route', skill: 'follow-route', route: [displacement]),
    ];
  }

  void remove(GameEntityHandle handle) {
    for (final team in _teams.values) {
      team.leave(handle);
    }
    clear();
  }

  bool ready(_RuntimeBrain actor) {
    if (actor.multi == null) return true;
    final definition = actor.definition;
    final members = owner._actors.values
        .where(
          (a) =>
              a.definition.teamId == definition.teamId &&
              owner.runtime().isEntityActive(a.identity.entity),
        )
        .toList();
    final positive = members
        .where((a) => a.definition.registeredRole == 1)
        .length;
    final negative = members.length - positive;
    final goal = actor.multi!.goal;
    return !members.any((a) => a.multiFailure != null) &&
        positive == 1 &&
        negative >= 1 &&
        negative <= (definition.multiTask == 'cooperative-search' ? 2 : 1) &&
        (goal == null || owner.runtime().isEntityActive(goal));
  }

  Map<GameEntityHandle, ObservationFrame> sample(SensorSnapshot snapshot) {
    if (_channels.isEmpty) return const {};
    var changed = false;
    for (final actor in owner._actors.values.where((a) => a.multi != null)) {
      final team = _teams[actor.definition.teamId]!;
      final handle = actor.identity.entity;
      if (!owner.runtime().isEntityActive(handle) && team.contains(handle)) {
        team.leave(handle);
        changed = true;
      } else if (owner.runtime().isEntityActive(handle) &&
          !team.contains(handle)) {
        team.join(actor.identity);
        changed = true;
      }
    }
    if (changed) clear();
    final actors = owner._actors.values
        .where(
          (a) =>
              a.multi != null &&
              owner.runtime().isEntityActive(a.identity.entity),
        )
        .toList();
    final frames = <GameEntityHandle, ObservationFrame>{};
    final poses = <GameEntityHandle, PhysicsPose>{};
    for (final team in _teams.values) {
      final members = actors
          .where((a) => a.definition.teamId == team.id)
          .toList();
      final handles = {
        for (final a in members) a.identity.entity,
        for (final a in members) ?a.multi!.goal,
      };
      final teamSnapshot = SensorSnapshot(
        episodeId: snapshot.episodeId,
        tick: snapshot.tick,
        worldRevision: snapshot.worldRevision,
        entities: [for (final handle in handles) ?snapshot.entities[handle]],
        world: owner.runtime().simulation!.world,
        colliders: snapshot.colliders,
        currentRevision: () => owner._session!.tick,
        geometryLoaded: (_, _) => !owner.runtime().isClosed,
      );
      final channel = _channels[team.id];
      if (channel == null) continue;
      if (members.any(
        (a) => !teamSnapshot.entities.containsKey(a.identity.entity),
      )) {
        channel.clear();
      }
      channel.capture(teamSnapshot);
      for (final actor in members) {
        final handle = actor.identity.entity;
        final pose = teamSnapshot.entities[handle]?.pose;
        if (pose == null) continue;
        poses[handle] = pose;
        final frame = actor.observer.build(teamSnapshot, handle);
        frames[handle] = frame;
        channel.observe(frame);
      }
    }
    _poses[snapshot.tick] = poses;
    _poses.removeWhere((tick, _) => tick < snapshot.tick - 2);
    for (final actor in actors) {
      final definition = actor.definition, profile = definition.multiProfile!;
      final goal = actor.multi!.goal;
      if (goal == null || snapshot.tick % profile.messageCadenceTicks != 0) {
        continue;
      }
      final team = _teams[definition.teamId]!;
      final channel = _channels[team.id]!;
      for (final recipient in team.members) {
        if (recipient.entity == actor.identity.entity) continue;
        channel.send(
          id: 'team-${snapshot.tick}-${actors.indexOf(actor)}-${actor.identity.entity.generation}-${team.members.indexOf(recipient)}-${recipient.entity.generation}',
          sender: actor.identity.entity,
          recipient: recipient.entity,
          target: goal,
          tick: snapshot.tick,
        );
      }
    }
    final result = <GameEntityHandle, ObservationFrame>{};
    for (final actor in actors) {
      final handle = actor.identity.entity,
          pose = poses[handle],
          frame = frames[handle];
      if (pose == null || frame == null) continue;
      for (final message in _channels[actor.definition.teamId]!.receive(
        handle,
        tick: snapshot.tick,
      )) {
        final captured = _poses[message.observedTick]?[message.sender.entity];
        if (captured != null) {
          actor.multi!.accept(
            message,
            senderPoseTick: message.observedTick,
            senderPose: captured,
            tick: snapshot.tick,
          );
        }
      }
      actor.multiObservationPose = pose;
      result[handle] = actor.multi!.compose(frame, observerPose: pose);
    }
    return result;
  }

  void clear() {
    for (final channel in _channels.values) {
      channel.clear();
    }
    _poses.clear();
  }
}
