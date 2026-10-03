part of '../../zyren_game_ai.dart';

final class CommunicationProfile {
  final int delayTicks, ttlTicks, maxPending, maxEventIds, maxMessagesPerActor;
  final double range;
  CommunicationProfile({
    this.delayTicks = 1,
    this.ttlTicks = 120,
    this.range = 20,
    this.maxPending = 256,
    this.maxEventIds = 4096,
    this.maxMessagesPerActor = 16,
  }) {
    _bounded(delayTicks, 36000, 'communication delay', zero: true);
    _bounded(ttlTicks, 36000, 'communication ttl');
    _bounded(maxPending, 256, 'pending messages');
    _bounded(maxEventIds, 4096, 'event ledger');
    _bounded(maxMessagesPerActor, 64, 'actor messages');
    if (!range.isFinite ||
        range <= 0 ||
        range > 100000 ||
        delayTicks >= ttlTicks) {
      throw ArgumentError('Invalid communication range or expiry.');
    }
  }
  String get hash => _hash(toJson());
  Map<String, Object> toJson() => {
    'delayTicks': delayTicks,
    'ttlTicks': ttlTicks,
    'range': range,
    'maxPending': maxPending,
    'maxEventIds': maxEventIds,
    'maxMessagesPerActor': maxMessagesPerActor,
  };
}

/// Position retains the sender's observation frame, never a live target pose.
final class TeamMessage {
  final String id, teamId, schemaHash, sensorProfileHash;
  final BrainIdentity sender, recipient;
  final GameEntityHandle target;
  final int observedTick, sentTick, dueTick, expiresTick;
  final Vec3 position;
  final SensorProvenance provenance;
  final int _senderEpoch, _recipientEpoch;
  final double _distance;
  TeamMessage._(
    this.id,
    this.teamId,
    this.sender,
    this.recipient,
    this.target,
    this.observedTick,
    this.sentTick,
    this.dueTick,
    this.expiresTick,
    this.position,
    this.provenance,
    this.schemaHash,
    this.sensorProfileHash,
    this._senderEpoch,
    this._recipientEpoch,
    this._distance,
  );
  TeamBeliefMessage get belief => TeamBeliefMessage(
    teamId: teamId,
    sender: sender,
    recipient: recipient,
    target: target,
    position: position,
    observedTick: observedTick,
    sentTick: sentTick,
    ttlTicks: expiresTick - observedTick,
    confidence: 1,
  );
}

final class _TeamObservation {
  final BrainIdentity identity;
  final int epoch, tick, worldRevision;
  final String schemaHash, sensorProfileHash;
  final List<ObservedEntity> entities;
  _TeamObservation(GameTeam team, ObservationFrame frame)
    : identity = team.identityFor(frame.entity)!,
      epoch = team.membershipEpoch(frame.entity),
      tick = frame.tick,
      worldRevision = frame.worldRevision,
      schemaHash = frame.schemaHash,
      sensorProfileHash = frame.sensorProfileHash,
      entities = List.unmodifiable([
        for (var i = 0; i < frame.entities.length; i++)
          if (frame.entityMask[i] == 1 &&
              frame.entities[i]?.provenance == SensorProvenance.visible)
            frame.entities[i]!,
      ]);
}

/// A host service supplies trusted snapshots and permitted observation frames.
/// External diagnostic tools never get send/receive capabilities.
final class TeamChannel {
  final CommunicationProfile profile;
  final Map<String, GameTeam> _teams;
  final _frames = <GameEntityHandle, _TeamObservation>{};
  final _positions = <GameEntityHandle, Vec3>{};
  final _pending = <TeamMessage>[];
  final _events = <String>{};
  int _snapshotTick = -1, _receiveTick = -1;
  int _worldRevision = -1;
  bool Function() _current = () => false;
  TeamChannel({required Iterable<GameTeam> teams, required this.profile})
    : _teams = _communicationTeams(teams) {
    if (_teams.isEmpty ||
        _teams.values.map((t) => t.episodeId).toSet().length != 1) {
      throw ArgumentError('Teams must share one episode.');
    }
  }
  String get episodeId => _teams.values.first.episodeId;
  int get pendingCount => _pending.length;
  int get eventCount => _events.length;
  GameTeam? _team(GameEntityHandle actor) {
    final matches = _teams.values.where((t) => t.contains(actor));
    if (matches.length != 1) return null;
    return matches.first;
  }

  void capture(SensorSnapshot snapshot) {
    if (snapshot.episodeId != episodeId ||
        snapshot.tick < _snapshotTick ||
        !snapshot.isCurrent) {
      throw ArgumentError('Foreign or stale communication snapshot.');
    }
    _snapshotTick = snapshot.tick;
    _worldRevision = snapshot.worldRevision;
    _current = () => snapshot.isCurrent;
    _positions.clear();
    for (final team in _teams.values) {
      for (final member in team.members) {
        final entry = snapshot.entities[member.entity];
        if (entry != null) _positions[member.entity] = entry.pose.position;
      }
    }
    _frames.removeWhere((actor, _) => _team(actor) == null);
    _pending.removeWhere((message) => !_valid(message, snapshot.tick));
  }

  void observe(ObservationFrame frame) {
    final team = _team(frame.entity);
    if (team == null ||
        frame.episodeId != episodeId ||
        frame.tick > _snapshotTick ||
        (_frames[frame.entity]?.tick ?? -1) > frame.tick) {
      throw ArgumentError('Foreign or stale communication observation.');
    }
    if (!_frames.containsKey(frame.entity) && _frames.length >= 64) {
      throw StateError('Communication observer budget exceeded.');
    }
    _frames[frame.entity] = _TeamObservation(team, frame);
  }

  bool send({
    required String id,
    required GameEntityHandle sender,
    required GameEntityHandle recipient,
    required GameEntityHandle target,
    required int tick,
  }) {
    _name(id);
    final team = _team(sender), destination = _team(recipient);
    final frame = _frames[sender],
        from = _positions[sender],
        to = _positions[recipient];
    if (tick != _snapshotTick ||
        tick < _receiveTick ||
        !_current() ||
        team == null ||
        !identical(team, destination) ||
        sender == recipient ||
        frame == null ||
        frame.worldRevision != _worldRevision ||
        frame.epoch != team.membershipEpoch(sender) ||
        frame.identity != team.identityFor(sender) ||
        from == null ||
        to == null ||
        frame.tick > tick ||
        tick - frame.tick >= profile.ttlTicks ||
        _events.contains(id) ||
        _events.length >= profile.maxEventIds ||
        _pending.length >= profile.maxPending ||
        _pending.where((m) => m.recipient.entity == recipient).length >=
            profile.maxMessagesPerActor) {
      return false;
    }
    final distance = from.distanceTo(to);
    if (!distance.isFinite || distance > profile.range) return false;
    ObservedEntity? seen;
    for (final candidate in frame.entities) {
      if (candidate.handle == target && candidate.tick == frame.tick) {
        seen = candidate;
        break;
      }
    }
    if (seen == null || !seen.localPosition.isFinite) {
      return false;
    }
    final expires = seen.tick + profile.ttlTicks,
        due = tick + profile.delayTicks;
    if (due >= expires) return false;
    _events.add(id);
    _pending.add(
      TeamMessage._(
        id,
        team.id,
        team.identityFor(sender)!,
        team.identityFor(recipient)!,
        target,
        seen.tick,
        tick,
        due,
        expires,
        seen.localPosition,
        seen.provenance,
        frame.schemaHash,
        frame.sensorProfileHash,
        team.membershipEpoch(sender),
        team.membershipEpoch(recipient),
        distance,
      ),
    );
    return true;
  }

  bool _valid(TeamMessage message, int tick) {
    final team = _teams[message.teamId];
    return tick < message.expiresTick &&
        team != null &&
        identical(_team(message.sender.entity), team) &&
        identical(_team(message.recipient.entity), team) &&
        team.identityFor(message.sender.entity) == message.sender &&
        team.identityFor(message.recipient.entity) == message.recipient &&
        team.membershipEpoch(message.sender.entity) == message._senderEpoch &&
        team.membershipEpoch(message.recipient.entity) ==
            message._recipientEpoch;
  }

  List<TeamMessage> receive(GameEntityHandle actor, {required int tick}) {
    if (tick < _receiveTick || tick < 0) {
      throw ArgumentError(
        'Communication time cannot rewind. Start a new channel for the episode.',
      );
    }
    _receiveTick = tick;
    final delivered = <TeamMessage>[];
    _pending.removeWhere((message) {
      if (!_valid(message, tick)) return true;
      if (message.recipient.entity == actor && tick >= message.dueTick) {
        delivered.add(message);
        return true;
      }
      return false;
    });
    return List.unmodifiable(delivered);
  }

  int deliverTo(BeliefStore memory, {required int tick}) {
    var count = 0;
    for (final message in receive(memory.identity.entity, tick: tick)) {
      if (memory.receive(
        message.belief,
        policy: TeamMemoryPolicy(
          teamId: message.teamId,
          delayTicks: profile.delayTicks,
          range: profile.range,
        ),
        tick: tick,
        senderDistance: message._distance,
        permitted: true,
      )) {
        count++;
      }
    }
    return count;
  }

  void clear() {
    _pending.clear();
    _frames.clear();
    _positions.clear();
  }
}

Map<String, GameTeam> _communicationTeams(Iterable<GameTeam> teams) {
  final bounded = _sensorBoundedCopy(teams, 8);
  final result = {for (final team in bounded) team.id: team};
  if (result.length != bounded.length ||
      bounded.isEmpty ||
      bounded.any(
        (team) => !identical(team.entities, bounded.first.entities),
      )) {
    throw ArgumentError(
      'Teams must have unique IDs and share one entity table.',
    );
  }
  return Map.unmodifiable(result);
}
