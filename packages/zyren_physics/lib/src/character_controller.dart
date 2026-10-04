part of 'physics.dart';

/// Metres and radians, using an upright capsule and world Y-up.
final class CharacterControllerSettings {
  static const version = 1;
  final double offset,
      maxSlope,
      slideSlope,
      stepHeight,
      stepWidth,
      snapDistance;
  CharacterControllerSettings({
    this.offset = .01,
    this.maxSlope = .7853981633974483,
    this.slideSlope = .7853981633974483,
    this.stepHeight = .25,
    this.stepWidth = .2,
    this.snapDistance = .2,
  }) {
    if (![
          offset,
          maxSlope,
          slideSlope,
          stepHeight,
          stepWidth,
          snapDistance,
        ].every((v) => v.isFinite && v >= 0) ||
        offset == 0 ||
        stepWidth == 0 ||
        maxSlope > slideSlope ||
        slideSlope >= 1.5707963267948966) {
      throw ArgumentError('Invalid character clearance or slope settings.');
    }
  }
  Map<String, Object> get json => {
    'offset': offset,
    'maxSlope': maxSlope,
    'slideSlope': slideSlope,
    'stepHeight': stepHeight,
    'stepWidth': stepWidth,
    'snapDistance': snapDistance,
  };
}

final class CharacterContact {
  final int collider;
  final int? body;
  final Vec3 normal, point;
  CharacterContact._(Map data)
    : collider = data['collider'] as int,
      body = data['body'] as int?,
      normal = _vec(data['normal']),
      point = _vec(data['point']);
}

final class CharacterMovement {
  final Vec3 translation;
  final bool grounded, sliding;
  final List<CharacterContact> contacts;
  CharacterMovement._(Map data)
    : translation = _vec(data['translation']),
      grounded = data['grounded'] as bool,
      sliding = data['sliding'] as bool,
      contacts = List.unmodifiable(
        (data['collisions'] as List).map((v) => CharacterContact._(v as Map)),
      );
}

/// Collision queries do not step the world. Call [move] once per fixed step,
/// before stepping the world, and keep the capsule clear of animation writers.
final class KinematicCharacterController {
  final PhysicsBody body;
  final PhysicsCollider collider;
  final CharacterControllerSettings settings;
  KinematicCharacterController({
    required this.body,
    required this.collider,
    CharacterControllerSettings? settings,
  }) : settings = settings ?? CharacterControllerSettings() {
    if (body.kind != BodyKind.kinematicPosition ||
        !identical(body.world, collider.world)) {
      throw ArgumentError('Use a position-kinematic body and its capsule.');
    }
  }

  CharacterMovement resolve(Vec3 translation) => _resolve(translation);

  CharacterMovement _resolve(
    Vec3 translation, {
    bool submitTarget = false,
    Quat? rotation,
  }) {
    if (!translation.isFinite) throw ArgumentError('Movement must be finite.');
    final orientation = rotation?.normalized();
    body.world._check(body);
    if (collider._removed || collider._epoch != body.world._epoch) {
      throw StateError('Collider handle is stale.');
    }
    return CharacterMovement._(
      body.world._send(submitTarget ? 'characterMoveTarget' : 'characterMove', {
            'body': body.id,
            'collider': collider.id,
            'translation': translation.storage,
            if (orientation != null)
              'rotation': [
                orientation.x,
                orientation.y,
                orientation.z,
                orientation.w,
              ],
            ...settings.json,
          })
          as Map,
    );
  }

  /// Submits the collision-resolved target. Gravity and jumping are host policy.
  ///
  /// Resolution and target submission share one native call. [rotation] changes
  /// the target orientation; omitting it keeps the body's current orientation.
  /// The world still advances only when you step it.
  CharacterMovement move(Vec3 translation, {Quat? rotation}) =>
      _resolve(translation, submitTarget: true, rotation: rotation);
}
