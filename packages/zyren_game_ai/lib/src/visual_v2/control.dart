part of '../../visual_v2.dart';

enum VisualMotionState {
  unknownGoal,
  unknownClearance,
  blockedRoute,
  stopped,
  moving,
}

final class VisualMotionDecision {
  final VisualMotionState state;
  final CharacterIntent? character;
  final VehicleIntent? vehicle;
  final double cameraYaw;
  final GameGoal? goal;
  const VisualMotionDecision._(
    this.state,
    this.character,
    this.vehicle,
    this.cameraYaw,
    this.goal,
  );
}

/// One actor, one captured goal, at most eight short-lived camera obstacles.
/// Control uses the public route follower and typed native intent mappings.
/// Current own state is allowed. Hidden target/body callbacks are not accepted.
final class VisualGoalController {
  final VisualNavigationProfile profile;
  final VisualNavigationMap map;
  final double maxSpeed, stoppingDeceleration, obstacleMaxSpeed;
  final NavigationWorld _world;
  late final NavigationFollower _follower;
  VisualCaptureIdentity _identity;
  VisualGoalBelief? _belief;
  VisualEstimate? _latest;
  VisualCapturePose? _capture;
  int _lastTick = -1, _acceptedTick = -1, _scan = 0;
  VisualGoalController({
    required this.profile,
    required this.map,
    required ColliderShape actorShape,
    required PhysicsPose actorOffset,
    required VisualCaptureIdentity identity,
    double? maxSpeed,
    this.stoppingDeceleration = 2,
    this.obstacleMaxSpeed = 5,
  }) : _identity = identity,
       maxSpeed = maxSpeed ?? (profile.family == 'guard' ? 2 : 3),
       _world = map._newWorld() {
    if (_pin(actorShape.json) != _pin(profile.actorShape.json) ||
        _pin(actorOffset.json) != _pin(profile.actorColliderOffset.json) ||
        map.mesh.settings.radius < profile.footprintRadius ||
        map.mesh.settings.height < profile.actorHeight ||
        identity.mapHash != map.hash ||
        identity.profileHash != profile.hash ||
        !this.maxSpeed.isFinite ||
        this.maxSpeed <= 0 ||
        this.maxSpeed > 3 ||
        !stoppingDeceleration.isFinite ||
        stoppingDeceleration <= 0 ||
        stoppingDeceleration > 20 ||
        !obstacleMaxSpeed.isFinite ||
        obstacleMaxSpeed < 0 ||
        obstacleMaxSpeed > 5) {
      throw ArgumentError('Control bounds or identity differ.');
    }
    _follower = NavigationFollower(
      _world,
      maxVisited: 4096,
      reachTolerance: profile.family == 'guard' ? .08 : .5,
      lookAhead: profile.family == 'guard' ? 0 : 2,
    );
  }
  Map<String, Object> toJson() => {
    'version': 2,
    'profileHash': profile.hash,
    'mapHash': map.hash,
    'actorShape': profile.actorShape.json,
    'actorColliderOffset': profile.actorColliderOffset.json,
    'footprintRadius': profile.footprintRadius,
    'maxSpeed': maxSpeed,
    'stoppingDeceleration': stoppingDeceleration,
    'obstacleMaxSpeed': obstacleMaxSpeed,
    'maxVisited': 4096,
    'reachTolerance': profile.family == 'guard' ? .08 : .5,
    'lookAhead': profile.family == 'guard' ? 0 : 2,
    'goalStopDistance': .7,
    'routeGoalTolerance': .1,
    'maxGoalAge': 600,
    'maxObstacleAge': 25,
    'maxSigma': .75,
    'sigmaGrowthPerTick': .001,
    'confidence': .9,
    'clearanceRangeOrigin': 'captured-own-footprint',
    'unknown': 'stop-and-bounded-scan',
    'vehicleCurve': 'unqualified-brake',
    'clearanceGeometry': 'sector-swept-footprint',
    'goalUncertainty': 'admission-expiry; own-state-footprint-independent',
  };
  String get configurationHash => _pin(toJson());
  VisualGoalBelief? get belief => _belief;
  int get routeRevision => _world.revision;
  NavigationRoute? get route => _follower.route;
  VisualCaptureIdentity get identity => _identity;
  void reset(VisualCaptureIdentity identity) {
    if (identity == _identity ||
        identity.mapHash != map.hash ||
        identity.profileHash != profile.hash) {
      throw ArgumentError('Cannot reset to a foreign map/profile.');
    }
    _identity = identity;
    _belief = null;
    _latest = null;
    _capture = null;
    _lastTick = -1;
    _acceptedTick = -1;
    _scan = 0;
    _follower.setGoal(null);
    _world.setObstacles(map.noEntry.map((v) => v.obstacle).toList());
  }

  bool accept({
    required VisualEstimate estimate,
    required VisualCapturePose captured,
    required int tick,
  }) {
    if (estimate.profileHash != profile.hash ||
        captured.identity != _identity ||
        tick != captured.applyTick ||
        captured.captureTick <= _acceptedTick ||
        tick <= _lastTick) {
      return false;
    }
    _acceptedTick = captured.captureTick;
    _capture = captured;
    _latest = estimate;
    if (estimate.target.admitted) {
      _belief = VisualGoalBelief._(captured, estimate.target);
    }
    // Invisible observations cannot rewrite a previously seen position or time.
    return true;
  }

  VisualMotionDecision _stop(
    VisualMotionState state,
    GameGoal? goal, {
    double? yaw,
  }) {
    if (state == VisualMotionState.unknownGoal) _follower.setGoal(null);
    // Clearance stops preserve route progress. Resetting on every scan would
    // send a quantized motor back to the current cell centre after each pause.
    // Deterministic full bounded scan. Movement is never used to discover space.
    final scan = yaw ?? [-math.pi, -math.pi / 2, 0.0, math.pi / 2][_scan++ % 4];
    return VisualMotionDecision._(
      state,
      profile.family == 'guard' ? const CharacterIntent() : null,
      profile.family == 'vehicle' ? const VehicleIntent(brake: 1) : null,
      scan,
      goal,
    );
  }

  VisualMotionDecision decide({
    required int tick,
    required PhysicsPose ownPose,
    required Vec3 ownVelocity,
    required double groundY,
  }) {
    if (tick < 0 ||
        tick <= _lastTick ||
        !groundY.isFinite ||
        groundY.abs() > 10000) {
      throw ArgumentError('Invalid control tick or ground height.');
    }
    _finite(ownPose.position);
    _finite(ownVelocity);
    _lastTick = tick;
    final goal = _belief?.goalAt(_identity, tick);
    if (goal == null) return _stop(VisualMotionState.unknownGoal, null);
    final at = Vec3(ownPose.position.x, groundY, ownPose.position.z),
        destination = goal.route.single;
    if ((destination - at).length <= .7) {
      return _stop(VisualMotionState.stopped, goal, yaw: 0);
    }
    final obstacles = <NavigationObstacle>[
      ...map.noEntry.map((v) => v.obstacle),
    ];
    final captured = _capture, latest = _latest;
    final age = captured == null ? 26 : tick - captured.captureTick;
    if (captured != null && latest != null && age >= 0 && age <= 25) {
      for (var i = 0; i < latest.obstacles.length; i++) {
        final obstacle = latest.obstacles[i];
        if (obstacle.confidence < .9) continue;
        final center = captured.groundPoint(obstacle.lateral, obstacle.forward);
        final rotation = captured.cameraRotation;
        final x = rotation.rotate(Vec3(obstacle.halfWidth, 0, 0)),
            z = rotation.rotate(Vec3(0, 0, obstacle.halfLength));
        final inflate = obstacle.sigma + obstacleMaxSpeed * age / 50;
        final hx = x.x.abs() + z.x.abs() + inflate,
            hz = x.z.abs() + z.z.abs() + inflate;
        obstacles.add(
          NavigationObstacle(
            'camera:$i',
            min: Vec3(center.x - hx, -10000, center.z - hz),
            max: Vec3(center.x + hx, 10000, center.z + hz),
          ),
        );
      }
    }
    final previous = _world.obstacles.values.toList();
    if (previous.length != obstacles.length ||
        List.generate(obstacles.length, (i) => i).any(
          (i) =>
              previous[i].id != obstacles[i].id ||
              previous[i].min != obstacles[i].min ||
              previous[i].max != obstacles[i].max,
        )) {
      _world.setObstacles(obstacles);
    }
    if (_follower.goal == null || (_follower.goal! - destination).length > .1) {
      _follower.setGoal(destination);
    }
    final delta = _follower.intent(at, maxSpeed / 50);
    if (delta.length < 1e-7) {
      return _stop(
        (destination - at).length <= (profile.family == 'guard' ? .2 : .75)
            ? VisualMotionState.stopped
            : VisualMotionState.blockedRoute,
        goal,
      );
    }
    final yawToRoute =
        math.atan2(delta.x, delta.z) -
        math.atan2(
          ownPose.rotation.rotate(const Vec3(0, 0, 1)).x,
          ownPose.rotation.rotate(const Vec3(0, 0, 1)).z,
        );
    var aim = math.atan2(math.sin(yawToRoute), math.cos(yawToRoute));
    CharacterIntent? character;
    var actualDirection = delta.normalized();
    if (profile.family == 'guard') {
      character = profile.controllerDecoder
          .decode(
            TrainingActions.encodeCharacter(
              CharacterIntent(
                moveX: actualDirection.x,
                moveZ: actualDirection.z,
              ),
            ),
          )!
          .character!;
      actualDirection = Vec3(character.moveX, 0, character.moveZ).normalized();
      final forward = ownPose.rotation.rotate(const Vec3(0, 0, 1));
      final desired =
          math.atan2(actualDirection.x, actualDirection.z) -
          math.atan2(forward.x, forward.z);
      aim = math.atan2(math.sin(desired), math.cos(desired));
    }
    final stepEnd = at + actualDirection * (maxSpeed / 50);
    final endCell = _world.mesh.locate(
      stepEnd,
      tolerance: _world.mesh.settings.maxStep + .06,
    );
    if (endCell == null || _world.blockedCells.contains(endCell)) {
      return _stop(VisualMotionState.blockedRoute, goal, yaw: aim);
    }
    if (profile.family == 'vehicle') {
      // A route tangent cannot certify the car's curved physical sweep.
      // Until a bounded native curvature contract is qualified, permit only
      // aligned straight motion with zero steering, otherwise brake.
      final ownForward = ownPose.rotation.rotate(const Vec3(0, 0, 1));
      if (aim.abs() > .01 ||
          Vec3(ownVelocity.x, 0, ownVelocity.z).length > .01 &&
              Vec3(
                    ownVelocity.x,
                    0,
                    ownVelocity.z,
                  ).normalized().dot(ownForward) <
                  .9999) {
        return _stop(VisualMotionState.unknownClearance, goal, yaw: aim);
      }
      actualDirection = Vec3(ownForward.x, 0, ownForward.z).normalized();
    }
    final speed = Vec3(ownVelocity.x, 0, ownVelocity.z).length;
    if (speed > maxSpeed + .1 ||
        captured == null ||
        latest == null ||
        age < 0 ||
        age > 25 ||
        !_clear(captured, latest, at, actualDirection, speed, tick)) {
      return _stop(VisualMotionState.unknownClearance, goal, yaw: aim);
    }
    if (profile.family == 'guard') {
      return VisualMotionDecision._(
        VisualMotionState.moving,
        character,
        null,
        aim,
        goal,
      );
    }
    const steer = 0.0;
    final brake = aim.abs() > math.pi / 2 || speed >= maxSpeed ? 1.0 : 0.0;
    final encoded = TrainingActions.encodeVehicle(
      VehicleIntent(steer: steer, throttle: brake == 0 ? .5 : 0, brake: brake),
    );
    return VisualMotionDecision._(
      VisualMotionState.moving,
      null,
      profile.controllerDecoder.decode(encoded)!.vehicle!,
      aim,
      goal,
    );
  }

  bool _clear(
    VisualCapturePose pose,
    VisualEstimate estimate,
    Vec3 at,
    Vec3 delta,
    double speed,
    int tick,
  ) {
    final local = _inverse(pose.cameraRotation).rotate(delta.normalized());
    final half = profile.camera.fieldOfView / 2;
    // Entire swept actor corridor, including stop distance, must fit known sectors.
    // Free ranges start at the captured own footprint, not the optical near plane.
    final travel =
        maxSpeed / 50 +
        math.max(speed, maxSpeed) * 2 / 50 +
        math.max(speed, maxSpeed) *
            math.max(speed, maxSpeed) /
            (2 * stoppingDeceleration);
    final radius =
        map.mesh.settings.radius +
        map.mesh.settings.cellSize / 2 +
        obstacleMaxSpeed * (tick - pose.captureTick) / 50;
    final offset = _inverse(pose.cameraRotation).rotate(
      at - Vec3(pose.actorPosition.x, pose.groundY, pose.actorPosition.z),
    );
    final start = Vec3(offset.x, 0, offset.z), end = start + local * travel;
    final endAngle = math.atan2(end.x, end.z);
    // Clearance certifies sector-swept actor footprints rooted at the captured
    // own footprint. Include the whole centre segment after lateral drift,
    // plus the footprint/uncertainty envelope, not just the requested tangent.
    final startAngle = start.length < 1e-8
        ? endAngle
        : math.atan2(start.x, start.z);
    final spread = math.atan2(radius, math.max(travel, radius));
    final angleLow = math.min(startAngle, endAngle) - spread;
    final angleHigh = math.max(startAngle, endAngle) + spread;
    if (angleLow < -half || angleHigh > half) return false;
    final required = math.max(start.length, end.length) + radius;
    final sectorWidth = half * 2 / 9;
    for (var i = 0; i < 9; i++) {
      final low = -half + i * sectorWidth, high = low + sectorWidth;
      if (high < angleLow || low > angleHigh) continue;
      final sector = estimate.clearance[i];
      if (sector.knownProbability < .9 || sector.freeMetres < required) {
        return false;
      }
    }
    return true;
  }
}
