part of '../../visual_v2.dart';

/// Version two never adds a private target or waypoint to the actor input.
final class VisualNavigationProfile {
  final String family, mode;
  final CameraProfile camera;
  VisualNavigationProfile({required this.family, required this.mode})
    : camera = CameraProfile(
        depth: mode != 'rgb',
        offset: Vec3(0, family == 'guard' ? .3 : .6, .35),
        far: 40,
        maxMetres: 40,
        cadenceTicks: 5,
        latencyTicks: 2,
      ) {
    if (!['guard', 'vehicle'].contains(family) ||
        !['rgb', 'depth', 'combined'].contains(mode)) {
      throw ArgumentError('Unknown visual navigation profile.');
    }
  }
  static const bodyFields = [
    'localVelocityX',
    'localVelocityY',
    'localVelocityZ',
    'angularVelocityY',
    'height',
    'headingSin',
    'headingCos',
    'cameraYawSin',
    'cameraYawCos',
    'valid',
  ];
  // These are the registered native TRAIN actor shapes. A deployment host must
  // supply the same actual collider shape before admitting this model profile.
  ColliderShape get actorShape => family == 'guard'
      ? const CapsuleShape(halfHeight: .5, radius: .3)
      : const BoxShape(Vec3(.8, .25, 1.2));
  PhysicsPose get actorColliderOffset => PhysicsPose();
  double get footprintRadius => family == 'guard' ? .3 : math.sqrt(2.08);
  double get actorHeight => family == 'guard' ? 1.6 : .5;
  static const clearanceRasterMargin = .1, clearanceFootprintPadding = .1;
  int get channels => mode == 'rgb'
      ? 3
      : mode == 'depth'
      ? 2
      : 5;
  int get imageWidth => channels * 84 * 84;
  int get width => imageWidth + 10;
  String get artifactFamily => '$family-visual-nav-$mode-v2';
  String get hash => _pin(toJson());
  ActionDecoder get controllerDecoder => family == 'guard'
      ? ActionDecoder.characterDiscrete()
      : ActionDecoder.vehiclePedals();
  ObservationSpec get spec => ObservationSpec(
    id: artifactFamily,
    version: 2,
    configurationHash: hash,
    fields: [
      ObservationField('camera', width: imageWidth, min: 0, max: 1),
      ObservationField('own-body', width: 10, min: -10000, max: 10000),
    ],
    maxEntities: 1,
    maxRays: 0,
    range: 40,
    cadenceTicks: 5,
    latencyTicks: 2,
  );
  Map<String, Object> toJson() => {
    'version': 2,
    'pipeline': 'visual-navigation-v2',
    'family': family,
    'mode': mode,
    'camera_profile': camera.toJson(),
    'body_fields': bodyFields,
    'layout': 'CHW-image-then-own-body',
    'actor_shape': actorShape.json,
    'actor_collider_offset': actorColliderOffset.json,
    'footprint_radius': footprintRadius,
    'actor_height': actorHeight,
    'clearance_range_origin': 'captured-own-footprint',
    'clearance_raster_margin': clearanceRasterMargin,
    'clearance_footprint_padding': clearanceFootprintPadding,
    'camera_normalization': 'identity',
    'body_normalization': 'verified-TRAIN-affine',
    'fixed_hz': 50,
    'estimate_action_hash': VisualEstimate.spec.hash,
    'controller_action_hash': controllerDecoder.spec.hash,
  };
  List<double> ownBody({
    required PhysicsPose pose,
    required Vec3 velocity,
    required Vec3 angularVelocity,
    required double cameraYaw,
  }) {
    _finite(pose.position);
    _finite(velocity);
    _finite(angularVelocity);
    _mount(cameraYaw);
    final local = _inverse(pose.rotation).rotate(velocity);
    final heading = pose.rotation.rotate(const Vec3(0, 0, 1));
    final yaw = math.atan2(heading.x, heading.z);
    return List.unmodifiable([
      local.x,
      local.y,
      local.z,
      angularVelocity.y,
      pose.position.y,
      math.sin(yaw),
      math.cos(yaw),
      math.sin(cameraYaw),
      math.cos(cameraYaw),
      1.0,
    ]);
  }

  MlTensor compose(MlTensor captured, {required List<double> ownBody}) {
    final expected = [1, camera.channels, 84, 84];
    if (captured.dtype != MlDtype.float32 ||
        captured.shape.length != 4 ||
        List.generate(
          4,
          (i) => i,
        ).any((i) => captured.shape[i] != expected[i]) ||
        ownBody.length != 10 ||
        ownBody.any((v) => !v.isFinite || v.abs() > 10000) ||
        ownBody[9] != 1 ||
        (ownBody[5] * ownBody[5] + ownBody[6] * ownBody[6] - 1).abs() > 1e-5 ||
        (ownBody[7] * ownBody[7] + ownBody[8] * ownBody[8] - 1).abs() > 1e-5) {
      throw ArgumentError('Camera or captured body ABI mismatch.');
    }
    final pixels = captured.float32Values, count = 84 * 84;
    if (pixels.any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw ArgumentError('Unavailable camera planes.');
    }
    if (camera.depth) {
      for (var i = 0; i < count; i++) {
        final valid = pixels[count * 4 + i];
        if (valid != 0 && valid != 1 ||
            valid == 0 && pixels[count * 3 + i] != 0) {
          throw ArgumentError('Depth validity mismatch.');
        }
      }
    }
    final result = Float32List(width)
      ..setRange(0, imageWidth, pixels, mode == 'depth' ? count * 3 : 0)
      ..setRange(imageWidth, width, ownBody);
    return MlTensor.float32([1, width], result);
  }
}

void _mount(double yaw) {
  if (!yaw.isFinite || yaw.abs() > math.pi) {
    throw ArgumentError('Camera yaw must be within [-pi,pi].');
  }
}

/// Every receipt is pinned to a capture epoch, not just a reusable actor ID.
final class VisualCaptureIdentity {
  final String episodeId, profileHash, modelHash, mapHash;
  final GameEntityHandle actor;
  final int gameEpoch, controlEpoch, stateEpoch, cameraRevision, mapRevision;
  VisualCaptureIdentity({
    required this.episodeId,
    required this.actor,
    required this.profileHash,
    required this.modelHash,
    required this.mapHash,
    required this.gameEpoch,
    required this.controlEpoch,
    required this.stateEpoch,
    required this.cameraRevision,
    required this.mapRevision,
  }) {
    _name(episodeId);
    for (final pin in [profileHash, modelHash, mapHash]) {
      _sha(pin);
    }
    if ([
      gameEpoch,
      controlEpoch,
      stateEpoch,
      cameraRevision,
      mapRevision,
    ].any((v) => v < 0 || v > 0x7fffffffffffffff)) {
      throw ArgumentError('Invalid capture epoch.');
    }
  }
  @override
  bool operator ==(Object other) =>
      other is VisualCaptureIdentity &&
      episodeId == other.episodeId &&
      actor == other.actor &&
      profileHash == other.profileHash &&
      modelHash == other.modelHash &&
      mapHash == other.mapHash &&
      gameEpoch == other.gameEpoch &&
      controlEpoch == other.controlEpoch &&
      stateEpoch == other.stateEpoch &&
      cameraRevision == other.cameraRevision &&
      mapRevision == other.mapRevision;
  @override
  int get hashCode => Object.hash(
    episodeId,
    actor,
    profileHash,
    modelHash,
    mapHash,
    gameEpoch,
    controlEpoch,
    stateEpoch,
    cameraRevision,
    mapRevision,
  );
}

/// Own state is copied before asynchronous readback. No resolver is retained.
final class VisualCapturePose {
  final VisualCaptureIdentity identity;
  final int captureTick, applyTick, worldRevision;
  final Vec3 actorPosition, cameraPosition;
  final Quat actorRotation, cameraRotation;
  final double groundY, cameraYaw;
  VisualCapturePose({
    required this.identity,
    required VisualNavigationProfile profile,
    required PhysicsPose actorPose,
    required this.groundY,
    required this.cameraYaw,
    required this.captureTick,
    required this.worldRevision,
  }) : actorPosition = actorPose.position,
       actorRotation = actorPose.rotation,
       cameraPosition =
           actorPose.position +
           actorPose.rotation.rotate(profile.camera.offset),
       cameraRotation =
           actorPose.rotation * Quat.axisAngle(const Vec3(0, 1, 0), cameraYaw),
       applyTick = captureTick + 2 {
    _finite(actorPosition);
    _finite(cameraPosition);
    _mount(cameraYaw);
    if (identity.profileHash != profile.hash ||
        worldRevision < 0 ||
        captureTick < 0 ||
        captureTick > 0x7ffffffffffffffd ||
        captureTick % 5 != 0 ||
        !groundY.isFinite ||
        groundY.abs() > 10000) {
      throw ArgumentError('Invalid captured pose or cadence.');
    }
    final q = actorRotation;
    if (![q.x, q.y, q.z, q.w].every((v) => v.isFinite) ||
        (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w - 1).abs() > 1e-5) {
      throw ArgumentError('Captured rotation must be unit length.');
    }
  }
  factory VisualCapturePose.fromCamera({
    required VisualCaptureIdentity identity,
    required VisualNavigationProfile profile,
    required CameraObservation observation,
    required double groundY,
  }) {
    if (observation.capturedActorPose == null ||
        observation.cameraProfileHash != profile.camera.hash ||
        observation.entity != identity.actor ||
        observation.episodeId != identity.episodeId) {
      throw ArgumentError('Foreign camera receipt.');
    }
    final pose = VisualCapturePose(
      identity: identity,
      profile: profile,
      actorPose: observation.capturedActorPose!,
      groundY: groundY,
      cameraYaw: observation.capturedMountYaw,
      captureTick: observation.receipt.tick,
      worldRevision: observation.worldRevision,
    );
    if (pose.cameraPosition != observation.capturedCameraPosition ||
        pose.cameraRotation != observation.capturedCameraRotation) {
      throw ArgumentError('Captured camera mount differs.');
    }
    return pose;
  }
  Vec3 groundPoint(double lateral, double forward) {
    final result =
        cameraPosition + cameraRotation.rotate(Vec3(lateral, 0, forward));
    return Vec3(result.x, groundY, result.z);
  }
}
