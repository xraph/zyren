part of '../../zyren_game_ai.dart';

/// Host-owned membership for one episode. Membership changes invalidate messages.
final class GameTeam {
  final String id, episodeId;
  final GameEntityTable entities;
  final int maxMembers, maxMembershipChanges;
  final _members = <GameEntityHandle, BrainIdentity>{};
  final _epochs = <GameEntityHandle, int>{};
  int _revision = 0;
  GameTeam({
    required this.id,
    required this.episodeId,
    required this.entities,
    this.maxMembers = 64,
    this.maxMembershipChanges = 4096,
  }) {
    _name(id);
    _name(episodeId);
    _bounded(maxMembers, 64, 'team members');
    _bounded(maxMembershipChanges, 4096, 'membership changes');
  }
  int get revision => _revision;
  List<BrainIdentity> get members => List.unmodifiable(
    _members.values.where((m) => entities.isAlive(m.entity)),
  );
  bool contains(GameEntityHandle actor) =>
      _members.containsKey(actor) && entities.isAlive(actor);
  BrainIdentity? identityFor(GameEntityHandle actor) =>
      contains(actor) ? _members[actor] : null;
  int membershipEpoch(GameEntityHandle actor) => _epochs[actor] ?? 0;
  void _change(GameEntityHandle actor) {
    if (_revision >= maxMembershipChanges) {
      throw StateError(
        'Team membership change budget exhausted. Start a new episode.',
      );
    }
    _epochs[actor] = ++_revision;
  }

  void join(BrainIdentity identity) {
    if (identity.episodeId != episodeId || !entities.isAlive(identity.entity)) {
      throw ArgumentError('Foreign episode or dead team member.');
    }
    for (final old
        in _members.keys.where((h) => !entities.isAlive(h)).toList()) {
      leave(old);
    }
    if (_members[identity.entity] == identity) return;
    if (!_members.containsKey(identity.entity) &&
        _members.length >= maxMembers) {
      throw StateError('Team member limit exceeded.');
    }
    _change(identity.entity);
    _members[identity.entity] = identity;
  }

  void leave(GameEntityHandle actor) {
    if (!_members.containsKey(actor)) return;
    _change(actor);
    _members.remove(actor);
  }
}

final class _MultiSighting {
  final GameEntityHandle target, sender;
  final Vec3 worldPosition;
  final int observedTick;
  const _MultiSighting(
    this.target,
    this.sender,
    this.worldPosition,
    this.observedTick,
  );
}

/// Exact registered role, authored route and delivered historical team input.
/// The adapter has no world/query API and cannot read a hidden target pose.
final class GameMultiObservationAdapter {
  final BrainIdentity identity;
  final TrainingMultiProfile profile;
  final String role;
  final GameEntityHandle? goal;
  final List<Vec3> authoredRoute;
  late final ObservationSpec _base = profile.assembler.spec,
      _spec = profile.spec;
  late final String _routeHash = _hash(
    authoredRoute.map((p) => p.storage).toList(),
  );
  int _routeIndex = 0, _lastTick = -1;
  _MultiSighting? _sighting;
  GameMultiObservationAdapter({
    required this.identity,
    required this.profile,
    required this.role,
    this.goal,
    List<Vec3> authoredRoute = const [],
  }) : authoredRoute = List.unmodifiable(authoredRoute) {
    if (!profile.roleNames.values.contains(role) ||
        (profile.task == 'cooperative-search') != (goal != null) ||
        authoredRoute.length > 32 ||
        authoredRoute.any(
          (p) => !p.isFinite || p.storage.any((v) => v.abs() > 100000),
        )) {
      throw ArgumentError(
        'Invalid registered team role, goal or authored route.',
      );
    }
  }
  int get routeIndex => _routeIndex;
  int? get receivedObservationTick => _sighting?.observedTick;

  /// The sender pose must be the captured pose from the message observation tick.
  bool accept(
    TeamMessage message, {
    required int senderPoseTick,
    required PhysicsPose senderPose,
    required int tick,
  }) {
    if (senderPoseTick != message.observedTick) {
      throw ArgumentError('Team bearing requires its captured sender pose.');
    }
    if (profile.messageTarget == 'none' ||
        message.recipient != identity ||
        message.target != goal ||
        message.provenance != SensorProvenance.visible ||
        message.schemaHash != _base.hash ||
        message.sensorProfileHash != _base.configurationHash ||
        tick < message.dueTick ||
        tick >= message.expiresTick ||
        message.observedTick < (_sighting?.observedTick ?? -1)) {
      return false;
    }
    final world =
        senderPose.position + senderPose.rotation.rotate(message.position);
    if (!world.isFinite) return false;
    _sighting = _MultiSighting(
      message.target,
      message.sender.entity,
      world,
      message.observedTick,
    );
    return true;
  }

  ObservationFrame compose(
    ObservationFrame frame, {
    required PhysicsPose observerPose,
  }) {
    if (frame.episodeId != identity.episodeId ||
        frame.entity != identity.entity ||
        frame.schemaHash != _base.hash ||
        frame.sensorProfileHash != _base.configurationHash ||
        frame.tensor.dtype != MlDtype.float32 ||
        frame.tensor.byteLength != _base.width * 4 ||
        frame.tensor.shape.length != 2 ||
        frame.tensor.shape[0] != 1 ||
        frame.tensor.shape[1] != _base.width ||
        frame.tick <= _lastTick) {
      throw ArgumentError('Foreign, stale or incompatible team observation.');
    }
    var cursor = _routeIndex;
    if (cursor < authoredRoute.length &&
        authoredRoute[cursor].distanceTo(observerPose.position) < .5) {
      cursor++;
      if (profile.task == 'competitive-pursuit' &&
          role == profile.roleNames['negative']) {
        cursor %= authoredRoute.length;
      }
    }
    final waypoint = cursor < authoredRoute.length
        ? authoredRoute[cursor] - observerPose.position
        : Vec3.zero;
    final values = Float32List(_spec.width)
      ..setRange(0, _base.width, frame.tensor.float32Values);
    values.setRange(_base.width, _base.width + 4, [
      role == profile.roleNames['positive'] ? 1 : -1,
      waypoint.x / profile.perception.range,
      waypoint.z / profile.perception.range,
      cursor < authoredRoute.length ? 1 : 0,
    ]);
    final sighting = _sighting;
    if (sighting != null &&
        frame.tick >= sighting.observedTick &&
        frame.tick - sighting.observedTick < profile.communication.ttlTicks &&
        profile.messageTarget != 'none') {
      final q = observerPose.rotation;
      final local = Quat(
        -q.x,
        -q.y,
        -q.z,
        q.w,
      ).rotate(sighting.worldPosition - observerPose.position);
      values.setRange(_base.width + 4, _spec.width, [
        local.x / profile.perception.range,
        local.y / profile.perception.range,
        local.z / profile.perception.range,
        (frame.tick - sighting.observedTick) / profile.communication.ttlTicks,
        1,
        1,
      ]);
    }
    if (values.any((v) => !v.isFinite || v.abs() > 10000)) {
      throw StateError(
        'Team augmentation exceeds the registered tensor bounds.',
      );
    }
    _routeIndex = cursor;
    _lastTick = frame.tick;
    if (sighting != null &&
        frame.tick - sighting.observedTick >= profile.communication.ttlTicks) {
      _sighting = null;
    }
    return ObservationFrame._(
      episodeId: frame.episodeId,
      schemaHash: _spec.hash,
      sensorProfileHash: _spec.configurationHash,
      entity: frame.entity,
      tick: frame.tick,
      worldRevision: frame.worldRevision,
      readings: frame.readings,
      entities: frame.entities,
      entityMask: frame.entityMask,
      tensor: MlTensor.float32([1, _spec.width], values),
    );
  }

  Map<String, Object?> snapshot({required int tick}) {
    if (tick < 0 || tick < _lastTick) {
      throw StateError('Invalid team checkpoint tick.');
    }
    final sighting = _sighting;
    return {
      'version': 1,
      'identity': _memoryIdentity(identity),
      'profileHash': profile.configurationHash,
      'role': role,
      'goal': goal == null ? null : _memoryHandle(goal!),
      'routeHash': _routeHash,
      'routeIndex': _routeIndex,
      'savedTick': tick,
      'sighting':
          sighting == null ||
              tick - sighting.observedTick >= profile.communication.ttlTicks
          ? null
          : {
              'target': _memoryHandle(sighting.target),
              'sender': _memoryHandle(sighting.sender),
              'worldPosition': sighting.worldPosition.storage,
              'observedTick': sighting.observedTick,
            },
    };
  }

  void restore(
    Map<String, Object?> data, {
    required int tick,
    required GameEntityHandle? Function(GameEntityHandle) remap,
  }) {
    if (data.length != 9 ||
        data['version'] != 1 ||
        data['savedTick'] != tick ||
        tick < 0 ||
        data['profileHash'] != profile.configurationHash ||
        data['role'] != role ||
        data['routeHash'] != _routeHash ||
        data['routeIndex'] is! int ||
        (data['routeIndex'] as int) < 0 ||
        (data['routeIndex'] as int) > authoredRoute.length) {
      throw const FormatException(
        'Team checkpoint profile, route or timing differs.',
      );
    }
    final saved = data['identity'] as Map;
    if (saved['modelHash'] != identity.modelHash ||
        remap(_readMemoryHandle(saved['entity'])) != identity.entity ||
        (data['goal'] == null
                ? null
                : remap(_readMemoryHandle(data['goal']))) !=
            goal) {
      throw const FormatException(
        'Team checkpoint actor or goal remap differs.',
      );
    }
    _MultiSighting? restored;
    final value = data['sighting'];
    if (value != null) {
      if (value is! Map ||
          value.length != 4 ||
          value['observedTick'] is! int ||
          (value['observedTick'] as int) < 0 ||
          (value['observedTick'] as int) > tick ||
          profile.messageTarget == 'none') {
        throw const FormatException('Invalid historical team sighting.');
      }
      final position = value['worldPosition'];
      if (position is! List ||
          position.length != 3 ||
          position.any((v) => v is! num || !v.isFinite || v.abs() > 1000000)) {
        throw const FormatException('Historical team position exceeds bounds.');
      }
      final target = remap(_readMemoryHandle(value['target'])),
          sender = remap(_readMemoryHandle(value['sender']));
      if (target != null &&
          sender != null &&
          tick - (value['observedTick'] as int) <
              profile.communication.ttlTicks) {
        if (target != goal) {
          throw const FormatException('Historical team goal changed.');
        }
        restored = _MultiSighting(
          target,
          sender,
          Vec3(
            (position[0] as num).toDouble(),
            (position[1] as num).toDouble(),
            (position[2] as num).toDouble(),
          ),
          value['observedTick'] as int,
        );
      }
    }
    _routeIndex = data['routeIndex'] as int;
    _sighting = restored;
    _lastTick = tick - 1;
  }

  void reset() {
    _routeIndex = 0;
    _lastTick = -1;
    _sighting = null;
  }
}
