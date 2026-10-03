part of '../zyren_game_native.dart';

/// Actor following uses native shape queries; it does not advance simulation.
final class GameCameraRig {
  final Camera camera;
  final GameSession session;
  final PhysicsWorld world;
  final PhysicsBody? Function(GameEntityHandle actor) resolveBody;
  final double radius, eyeHeight, thirdPersonDistance, vehicleDistance;
  GameCameraMode mode;
  GameEntityHandle? _actor;
  GameEntityHandle? get actor => _actor;
  GameCameraRig({
    required this.camera,
    required this.session,
    required this.world,
    required this.resolveBody,
    this.mode = GameCameraMode.thirdPerson,
    this.radius = .15,
    this.eyeHeight = .6,
    this.thirdPersonDistance = 4,
    this.vehicleDistance = 8,
  }) {
    if (![
          radius,
          eyeHeight,
          thirdPersonDistance,
          vehicleDistance,
        ].every((v) => v.isFinite) ||
        radius <= 0 ||
        radius > 2 ||
        eyeHeight < 0 ||
        eyeHeight > 10 ||
        thirdPersonDistance <= radius ||
        thirdPersonDistance > 100 ||
        vehicleDistance <= radius ||
        vehicleDistance > 100) {
      throw ArgumentError('Invalid camera rig constraints.');
    }
  }
  factory GameCameraRig.fromDefinition({
    required Camera camera,
    required GameSession session,
    required PhysicsWorld world,
    required PhysicsBody? Function(GameEntityHandle actor) resolveBody,
    required GameCameraDefinition definition,
  }) {
    final rig = GameCameraRig(
      camera: camera,
      session: session,
      world: world,
      resolveBody: resolveBody,
      mode: definition.mode,
      radius: definition.radius,
      eyeHeight: definition.eyeHeight,
      thirdPersonDistance: definition.thirdPersonDistance,
      vehicleDistance: definition.vehicleDistance,
    );
    if (definition.target != null) {
      final actor = session.entities.entities
          .where((e) => e.handle.id == definition.target)
          .firstOrNull;
      if (actor == null) {
        throw StateError('Camera authored target is unavailable.');
      }
      rig.follow(actor.handle);
    }
    return rig;
  }
  void follow(GameEntityHandle? actor) {
    if (actor != null &&
        (session.isClosed || !session.entities.isAlive(actor))) {
      throw StateError('Camera actor is stale.');
    }
    _actor = actor;
  }

  ({Vec3 position, Vec3 target})? _pose(CharacterIntent intent) {
    intent.validate();
    final actor = _actor;
    if (actor == null) return null;
    final body = resolveBody(actor);
    if (session.isClosed ||
        !session.entities.isAlive(actor) ||
        body == null ||
        !body.isAlive ||
        !identical(body.world, world)) {
      _actor = null;
      return null;
    }
    final anchor = body.state.pose.position + Vec3(0, eyeHeight, 0);
    final pitch = intent.lookPitch.clamp(-1.4, 1.4);
    final forward = Vec3(
      math.sin(intent.lookYaw) * math.cos(pitch),
      math.sin(pitch),
      math.cos(intent.lookYaw) * math.cos(pitch),
    );
    if (mode == GameCameraMode.firstPerson) {
      return (position: anchor, target: anchor + forward);
    }
    final distance = mode == GameCameraMode.vehicle
        ? vehicleDistance
        : thirdPersonDistance;
    final offset = -forward * distance;
    final hit = world.shapeCast(
      shape: SphereShape(radius),
      pose: PhysicsPose(position: anchor),
      velocity: offset,
      maxTime: 1,
      filter: QueryFilter(excludeBody: body, excludeSensors: true),
    );
    final fraction = hit == null
        ? 1.0
        : math.max(0.0, hit.time - .02 / distance);
    final position = anchor + offset * fraction;
    return (
      position: position,
      target: fraction * distance < .01 ? anchor + forward : anchor,
    );
  }

  bool update(CharacterIntent intent) {
    final pose = _pose(intent);
    if (pose == null) return false;
    camera.batch(() {
      camera.position = pose.position;
      camera.target = pose.target;
      camera.up = const Vec3(0, 1, 0);
    });
    return true;
  }

  /// Captures an obstruction-checked destination for the existing timeline.
  CameraTrack trackToActor(
    Duration duration, {
    CharacterIntent intent = const CharacterIntent(),
  }) {
    if (duration <= Duration.zero || duration > const Duration(minutes: 1)) {
      throw ArgumentError('Camera transition must be within (0,1min].');
    }
    final pose = _pose(intent);
    if (pose == null) throw StateError('Camera actor is unavailable.');
    return CameraTrack(camera, [
      CameraKeyframe(
        Duration.zero,
        position: camera.position,
        target: camera.target,
        up: camera.up,
      ),
      CameraKeyframe(
        duration,
        position: pose.position,
        target: pose.target,
        up: const Vec3(0, 1, 0),
      ),
    ]);
  }
}
