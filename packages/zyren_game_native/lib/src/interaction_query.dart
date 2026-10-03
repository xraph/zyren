part of '../zyren_game_native.dart';

final class GameInteractionCandidate {
  final GameEntityHandle target;
  final String id, label;
  final double distance;
  final Object _origin;
  GameInteractionCandidate._(
    this.target,
    this.id,
    this.label,
    this.distance,
    this._origin,
  );
}

final class _GameInteractionBinding {
  final GameEntityHandle target;
  final Object3D object;
  final PhysicsBody body;
  final String id, label;
  final void Function(GameEntityHandle actor) execute;
  late final Registration registration;
  _GameInteractionBinding(
    this.target,
    this.object,
    this.body,
    this.id,
    this.label,
    this.execute,
  );
}

/// Bounded game candidates share the existing scene pointer interaction router.
final class InteractionQuery {
  final GameSession session;
  final PhysicsWorld world;
  final SceneInteractionRouter router;
  final PhysicsBody? Function(GameEntityHandle actor) resolveBody;
  final GameEntityHandle? Function()? pointerActor;
  final bool Function(GameEntityHandle actor, GameEntityHandle target)?
  canInteract;
  final double reach;
  final int maxCandidates, maxTargets;
  final Map<GameEntityHandle, _GameInteractionBinding> _bindings = {};
  bool _closed = false;
  InteractionQuery({
    required this.session,
    required this.world,
    required this.router,
    required this.resolveBody,
    this.pointerActor,
    this.canInteract,
    this.reach = 2,
    this.maxCandidates = 16,
    this.maxTargets = 128,
  }) {
    if (!reach.isFinite ||
        reach <= 0 ||
        reach > 100 ||
        maxCandidates < 1 ||
        maxCandidates > 128 ||
        maxTargets < 1 ||
        maxTargets > 1024) {
      throw ArgumentError('Invalid interaction bounds.');
    }
  }
  factory InteractionQuery.fromDefinition({
    required GameSession session,
    required PhysicsWorld world,
    required SceneInteractionRouter router,
    required PhysicsBody? Function(GameEntityHandle actor) resolveBody,
    required GameInteractionDefinition definition,
    GameEntityHandle? Function()? pointerActor,
    bool Function(GameEntityHandle actor, GameEntityHandle target)? canInteract,
  }) => InteractionQuery(
    session: session,
    world: world,
    router: router,
    resolveBody: resolveBody,
    pointerActor: pointerActor,
    canInteract: canInteract,
    reach: definition.reach,
    maxCandidates: definition.maxCandidates,
    maxTargets: definition.maxTargets,
  );
  Registration register({
    required GameEntityHandle target,
    required Object3D object,
    required PhysicsBody body,
    required String id,
    required String label,
    required void Function(GameEntityHandle actor) onExecute,
  }) {
    if (_closed ||
        router.isDisposed ||
        session.isClosed ||
        !session.entities.isAlive(target) ||
        !body.isAlive ||
        !identical(body.world, world) ||
        _bindings.containsKey(target) ||
        _bindings.length >= maxTargets ||
        id.isEmpty ||
        id.length > 128 ||
        label.isEmpty ||
        label.length > 256) {
      throw StateError(
        'Interaction requires a unique live target within the registry bounds.',
      );
    }
    final binding = _GameInteractionBinding(
      target,
      object,
      body,
      id,
      label,
      onExecute,
    );
    final pointer = router.register(object, (event) {
      if (event.phase != ObjectPointerPhase.tap) return;
      final actor = pointerActor?.call();
      if (actor == null) return;
      final candidate = _candidate(actor, binding);
      if (candidate != null) execute(actor, candidate);
    });
    binding.registration = Registration(() {
      if (identical(_bindings[target], binding)) _bindings.remove(target);
      pointer.dispose();
    });
    _bindings[target] = binding;
    return binding.registration;
  }

  bool _visibleMember(Object3D object) {
    for (Object3D? node = object; node != null; node = node.parent) {
      if (!node.visible) return false;
      if (identical(node, router.scene)) return true;
    }
    return false;
  }

  GameInteractionCandidate? _candidate(
    GameEntityHandle actor,
    _GameInteractionBinding binding,
  ) {
    bool current() =>
        !_closed &&
        !router.isDisposed &&
        !session.isClosed &&
        !session.paused &&
        session.fault == null &&
        session.entities.isAlive(actor) &&
        actor != binding.target &&
        session.entities.isAlive(binding.target) &&
        binding.body.isAlive &&
        _visibleMember(binding.object) &&
        identical(_bindings[binding.target], binding) &&
        router.registeredObjects.contains(binding.object);
    if (_closed ||
        router.isDisposed ||
        session.isClosed ||
        session.paused ||
        session.fault != null ||
        !session.entities.isAlive(actor) ||
        actor == binding.target ||
        !session.entities.isAlive(binding.target) ||
        !binding.body.isAlive ||
        !_visibleMember(binding.object) ||
        !router.registeredObjects.contains(binding.object) ||
        !identical(_bindings[binding.target], binding)) {
      return null;
    }
    if (canInteract?.call(actor, binding.target) == false || !current()) {
      return null;
    }
    final body = resolveBody(actor);
    if (body == null ||
        !body.isAlive ||
        !identical(body.world, world) ||
        !current()) {
      return null;
    }
    final origin = body.state.pose.position,
        delta = binding.body.state.pose.position - origin;
    final distance = delta.length;
    if (distance > reach) return null;
    if (distance > 1e-6) {
      final hit = world.rayCast(
        origin: origin,
        direction: delta / distance,
        maxDistance: distance,
        filter: QueryFilter(excludeBody: body, excludeSensors: true),
      );
      if (hit != null && hit.body != binding.body.id) return null;
    }
    return GameInteractionCandidate._(
      binding.target,
      binding.id,
      binding.label,
      distance,
      binding,
    );
  }

  List<GameInteractionCandidate> available(GameEntityHandle actor) {
    final candidates = <GameInteractionCandidate>[];
    for (final binding in _bindings.values.toList()) {
      final candidate = _candidate(actor, binding);
      if (candidate != null) candidates.add(candidate);
    }
    candidates.sort((a, b) {
      final byDistance = a.distance.compareTo(b.distance);
      return byDistance != 0 ? byDistance : a.target.id.compareTo(b.target.id);
    });
    return List.unmodifiable(candidates.take(maxCandidates));
  }

  bool execute(GameEntityHandle actor, GameInteractionCandidate candidate) {
    final binding = _bindings[candidate.target];
    if (binding == null ||
        !identical(binding, candidate._origin) ||
        _candidate(actor, binding) == null) {
      return false;
    }
    binding.execute(actor);
    return true;
  }

  void close() {
    if (_closed) return;
    _closed = true;
    for (final binding in _bindings.values.toList()) {
      binding.registration.dispose();
    }
    _bindings.clear();
  }
}
