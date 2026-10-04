part of '../../zyren_game_ai.dart';

/// Service-only world input. Policies receive [ObservationFrame], never this.
final class SensorEntity {
  final GameEntityHandle handle;
  final PhysicsPose pose;
  final Vec3 velocity;
  final Vec3 angularVelocity;
  final PhysicsBody? body;
  final bool? grounded;
  final List<double>? affordances;
  SensorEntity({
    required this.handle,
    required this.pose,
    this.velocity = Vec3.zero,
    this.angularVelocity = Vec3.zero,
    this.body,
    this.grounded,
    List<double>? affordances,
  }) : affordances = affordances == null
           ? null
           : List.unmodifiable(affordances) {
    if (!velocity.isFinite ||
        !angularVelocity.isFinite ||
        (affordances != null &&
            (affordances.length > 64 ||
                affordances.any((v) => !v.isFinite || v < 0 || v > 1)))) {
      throw ArgumentError('Invalid body or affordance input.');
    }
  }
}

final class SensorCollider {
  final SensorMaterial material;
  final GameEntityHandle? entity;
  const SensorCollider(this.material, {this.entity});
}

final class SensorSnapshot {
  final String episodeId;
  final int tick, worldRevision;
  final Map<GameEntityHandle, SensorEntity> entities;
  final Map<int, SensorCollider> colliders;
  final PhysicsWorld? _world;
  final int Function() _revision;
  final bool Function(Vec3 from, Vec3 to) _geometryLoaded;
  final List<SensorSoundSample> _sounds;
  factory SensorSnapshot({
    required String episodeId,
    required int tick,
    required int worldRevision,
    required Iterable<SensorEntity> entities,
    required Map<int, SensorCollider> colliders,
    PhysicsWorld? world,
    required int Function() currentRevision,
    required bool Function(Vec3, Vec3) geometryLoaded,
    List<SensorSoundSample> sounds = const [],
  }) {
    _name(episodeId);
    if (tick < 0 ||
        worldRevision < 0 ||
        colliders.length > 65536 ||
        sounds.length > 4096) {
      throw ArgumentError('Snapshot limit exceeded.');
    }
    final bounded = _sensorBoundedCopy(entities, 16384);
    final byHandle = {for (final e in bounded) e.handle: e};
    if (byHandle.length != bounded.length) {
      throw ArgumentError('Duplicate snapshot entity.');
    }
    return SensorSnapshot._(
      episodeId,
      tick,
      worldRevision,
      Map.unmodifiable(byHandle),
      Map.unmodifiable(colliders),
      world,
      currentRevision,
      geometryLoaded,
      List.unmodifiable(sounds),
    );
  }
  SensorSnapshot._(
    this.episodeId,
    this.tick,
    this.worldRevision,
    this.entities,
    this.colliders,
    this._world,
    this._revision,
    this._geometryLoaded,
    this._sounds,
  );

  /// Adapt live game and character handles without reading each body separately.
  factory SensorSnapshot.fromSimulation({
    required String episodeId,
    required int worldRevision,
    required GameSimulation simulation,
    required Map<GameEntityHandle, PhysicsBody> bindings,
    required Map<int, SensorCollider> colliders,
    required int Function() currentRevision,
    required bool Function(Vec3, Vec3) geometryLoaded,
    Iterable<GameCharacterController> characters = const [],
    Map<GameEntityHandle, List<double>> affordances = const {},
    List<GameSoundEvent> sounds = const [],
  }) {
    if (bindings.length > 16384 || sounds.length > 4096) {
      throw ArgumentError('Snapshot input limit exceeded.');
    }
    final live = <GameEntityHandle, PhysicsBody>{
      for (final e in bindings.entries)
        if (simulation.session.entities.isAlive(e.key)) e.key: e.value,
    };
    final grounded = <GameEntityHandle, bool>{};
    var count = 0;
    for (final controller in characters) {
      if (++count > 4096) {
        throw ArgumentError('Character snapshot limit exceeded.');
      }
      if (!identical(controller.session, simulation.session)) {
        throw ArgumentError('Foreign character session.');
      }
      final body = controller.motor.controller.body;
      if (simulation.session.entities.isAlive(controller.actor) &&
          body.isAlive) {
        live[controller.actor] = body;
        grounded[controller.actor] = controller.grounded;
      }
    }
    return SensorSnapshot.fromPhysics(
      episodeId: episodeId,
      tick: simulation.session.tick,
      worldRevision: worldRevision,
      world: simulation.world,
      bindings: live,
      colliders: colliders,
      currentRevision: currentRevision,
      geometryLoaded: geometryLoaded,
      grounded: grounded,
      affordances: affordances,
      sounds: sounds.map(SensorSoundSample.fromEvent).toList(),
    );
  }
  bool get isCurrent => _revision() == worldRevision;

  /// Capture all native body states once, in the sensors phase after physics.
  factory SensorSnapshot.fromPhysics({
    required String episodeId,
    required int tick,
    required int worldRevision,
    required PhysicsWorld world,
    required Map<GameEntityHandle, PhysicsBody> bindings,
    required Map<int, SensorCollider> colliders,
    required int Function() currentRevision,
    required bool Function(Vec3, Vec3) geometryLoaded,
    Map<GameEntityHandle, bool> grounded = const {},
    Map<GameEntityHandle, List<double>> affordances = const {},
    List<SensorSoundSample> sounds = const [],
  }) {
    if (bindings.length > 16384 ||
        colliders.length > 65536 ||
        sounds.length > 4096) {
      throw ArgumentError('Snapshot input limit exceeded.');
    }
    final states = {for (final state in world.states) state.id: state};
    final captured = <SensorEntity>[];
    for (final entry in bindings.entries) {
      final state = states[entry.value.id];
      if (!identical(entry.value.world, world)) {
        throw ArgumentError('Foreign body binding.');
      }
      if (state == null || !entry.value.isAlive) continue;
      captured.add(
        SensorEntity(
          handle: entry.key,
          pose: state.pose,
          velocity: state.velocity,
          angularVelocity: state.angularVelocity,
          body: entry.value,
          grounded: grounded[entry.key],
          affordances: affordances[entry.key],
        ),
      );
    }
    return SensorSnapshot(
      episodeId: episodeId,
      tick: tick,
      worldRevision: worldRevision,
      world: world,
      entities: captured,
      colliders: colliders,
      currentRevision: currentRevision,
      geometryLoaded: geometryLoaded,
      sounds: sounds,
    );
  }
}

final class _QueryBudget {
  int remaining, used = 0;
  _QueryBudget(this.remaining);
  bool take() {
    if (remaining == 0) return false;
    remaining--;
    used++;
    return true;
  }
}

final class _RayResult {
  final SensorState state;
  final bool blocked;
  final double distance;
  final String? reason;
  const _RayResult(this.state, this.blocked, this.distance, [this.reason]);
}

List<_RayResult> _rays(
  SensorSnapshot snapshot,
  SensorEntity actor,
  List<Vec3> endpoints,
  SensorProfile profile,
  _QueryBudget budget,
) {
  // Transparent hits consume a variable number of queries. Preserve their
  // sequential admission order so they cannot borrow another ray's budget.
  if (profile.materials.containsValue(SensorMaterialRule.pass)) {
    return [
      for (final to in endpoints) _ray(snapshot, actor, to, profile, budget),
    ];
  }
  final results = <_RayResult>[];
  final rays = <PhysicsRay>[];
  final slots = <int>[];
  final world = snapshot._world;
  final from = actor.pose.position;
  for (final to in endpoints) {
    final delta = to - from;
    final distance = delta.length;
    if (!snapshot.isCurrent) {
      results.add(
        const _RayResult(SensorState.unknown, false, 0, 'snapshot-revision'),
      );
    } else if (world == null || world.isClosed) {
      results.add(
        const _RayResult(
          SensorState.unavailable,
          false,
          0,
          'physics-unavailable',
        ),
      );
    } else if (!snapshot._geometryLoaded(from, to)) {
      results.add(
        const _RayResult(SensorState.unknown, false, 0, 'geometry-unloaded'),
      );
    } else if (distance <= 1e-9) {
      results.add(const _RayResult(SensorState.known, false, 0));
    } else if (!budget.take()) {
      results.add(
        const _RayResult(SensorState.unknown, false, 0, 'query-budget'),
      );
    } else {
      slots.add(results.length);
      results.add(const _RayResult(SensorState.unknown, false, 0));
      rays.add(
        PhysicsRay(
          origin: from,
          direction: delta / distance,
          maxDistance: distance,
          solid: false,
        ),
      );
    }
  }
  if (rays.isEmpty) return results;
  List<QueryHit?> hits;
  try {
    hits = world!.rayCastBatch(
      rays,
      filter: QueryFilter(
        excludeBody: actor.body,
        excludeSensors: true,
        filter: profile.layerMask,
      ),
    );
  } on PhysicsException {
    for (final slot in slots) {
      results[slot] = const _RayResult(
        SensorState.unavailable,
        false,
        0,
        'query-failed',
      );
    }
    return results;
  } on StateError {
    for (final slot in slots) {
      results[slot] = const _RayResult(
        SensorState.unavailable,
        false,
        0,
        'query-failed',
      );
    }
    return results;
  }
  final current = snapshot.isCurrent;
  for (var i = 0; i < hits.length; i++) {
    results[slots[i]] = current
        ? _rayHit(snapshot, hits[i], profile, rays[i].maxDistance, 0)!
        : const _RayResult(SensorState.unknown, false, 0, 'snapshot-revision');
  }
  return results;
}

// A null result means an explicitly passable surface needs another query.
_RayResult? _rayHit(
  SensorSnapshot snapshot,
  QueryHit? hit,
  SensorProfile profile,
  double distance,
  double travelled, {
  GameEntityHandle? target,
}) {
  if (hit == null) return _RayResult(SensorState.known, false, distance);
  final metadata = snapshot.colliders[hit.collider];
  if (target != null && metadata?.entity == target) {
    return _RayResult(SensorState.known, false, distance);
  }
  final rule = profile.materials[metadata?.material ?? SensorMaterial.unknown]!;
  return switch (rule) {
    SensorMaterialRule.unknown => const _RayResult(
      SensorState.unknown,
      false,
      0,
      'material-unknown',
    ),
    SensorMaterialRule.block => _RayResult(
      SensorState.known,
      true,
      travelled + hit.time,
    ),
    SensorMaterialRule.pass => null,
  };
}

_RayResult _ray(
  SensorSnapshot snapshot,
  SensorEntity actor,
  Vec3 to,
  SensorProfile profile,
  _QueryBudget budget, {
  GameEntityHandle? target,
}) {
  final from = actor.pose.position;
  final delta = to - from;
  final distance = delta.length;
  if (!snapshot.isCurrent) {
    return const _RayResult(SensorState.unknown, false, 0, 'snapshot-revision');
  }
  final world = snapshot._world;
  if (world == null || world.isClosed) {
    return const _RayResult(
      SensorState.unavailable,
      false,
      0,
      'physics-unavailable',
    );
  }
  if (!snapshot._geometryLoaded(from, to)) {
    return const _RayResult(SensorState.unknown, false, 0, 'geometry-unloaded');
  }
  if (distance <= 1e-9) return const _RayResult(SensorState.known, false, 0);
  final direction = delta / distance;
  var travelled = 0.0;
  // Transparent surfaces consume additional native queries, all within budget.
  while (travelled < distance) {
    if (!budget.take()) {
      return const _RayResult(SensorState.unknown, false, 0, 'query-budget');
    }
    QueryHit? hit;
    try {
      hit = world.rayCast(
        origin: from + direction * travelled,
        direction: direction,
        maxDistance: distance - travelled,
        solid: false,
        filter: QueryFilter(
          excludeBody: actor.body,
          excludeSensors: true,
          filter: profile.layerMask,
        ),
      );
    } on PhysicsException {
      return const _RayResult(
        SensorState.unavailable,
        false,
        0,
        'query-failed',
      );
    } on StateError {
      return const _RayResult(
        SensorState.unavailable,
        false,
        0,
        'query-failed',
      );
    }
    if (!snapshot.isCurrent) {
      return const _RayResult(
        SensorState.unknown,
        false,
        0,
        'snapshot-revision',
      );
    }
    final result = _rayHit(
      snapshot,
      hit,
      profile,
      distance,
      travelled,
      target: target,
    );
    if (result != null) return result;
    travelled += math.max(hit!.time, 1e-5) + 1e-5;
  }
  return _RayResult(SensorState.known, false, distance);
}

List<T> _sensorBoundedCopy<T>(Iterable<T> source, int limit) {
  final copied = <T>[];
  for (final item in source) {
    if (copied.length == limit) {
      throw ArgumentError('Sensor iterable limit exceeded.');
    }
    copied.add(item);
  }
  return copied;
}

int _catalogQuota(int total, int slots, int slot) =>
    total ~/ slots + (slot < total % slots ? 1 : 0);
