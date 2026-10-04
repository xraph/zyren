part of '../../zyren_game_ai.dart';

/// Shared camera/body ABI for training and deployment. No acceptance claim.
abstract final class TrainingVisualProfiles {
  static TrainingVisualProfile forFamily({
    required String family,
    required String mode,
  }) {
    if (!['guard', 'vehicle'].contains(family) ||
        !['rgb', 'depth', 'combined'].contains(mode)) {
      throw ArgumentError('Unknown visual controller family or camera mode.');
    }
    return TrainingVisualProfile._(family, mode);
  }
}

/// Flat normalized CHW camera planes followed by captured own-body features.
/// The goal is the fixed forward driving/search task, never a live target pose.
final class TrainingVisualProfile {
  final String family, mode;
  final CameraProfile camera;
  TrainingVisualProfile._(this.family, this.mode)
    : camera = CameraProfile(
        depth: mode != 'rgb',
        offset: Vec3(0, family == 'guard' ? .3 : .6, .35),
        far: 40,
        maxMetres: 40,
      );

  static const bodyFields = [
    'localVelocityX',
    'localVelocityY',
    'localVelocityZ',
    'angularVelocityY',
    'height',
    'forwardGoal',
    'lateralGoal',
    'valid',
  ];
  int get channels => mode == 'rgb'
      ? 3
      : mode == 'depth'
      ? 2
      : 5;
  int get imageWidth => channels * camera.width * camera.height;
  int get bodyWidth => 8;
  int get fixedHz => 50;
  int get maxHoldTicks => 2;
  int get width => imageWidth + bodyWidth;
  String get artifactFamily => '$family-visual-$mode';
  String get configurationHash => _hash(toJson());
  ActionDecoder get decoder => family == 'guard'
      ? ActionDecoder.characterDiscrete()
      : ActionDecoder.vehiclePedals();
  ObservationSpec get spec => ObservationSpec(
    id: '$artifactFamily-v1',
    configurationHash: configurationHash,
    fields: [
      ObservationField('camera', width: imageWidth, min: 0, max: 1),
      ObservationField('own-body', width: bodyWidth, min: -10000, max: 10000),
    ],
    maxEntities: 1,
    maxRays: 0,
    range: 40,
    cadenceTicks: 1,
    latencyTicks: 1,
  );
  Map<String, Object> toJson() => {
    'version': 1,
    'family': family,
    'mode': mode,
    'layout': 'CHW-image-then-own-body',
    'camera_profile': camera.toJson(),
    'channels': channels,
    'fixed_hz': fixedHz,
    'max_hold_ticks': maxHoldTicks,
    'body_fields': bodyFields,
    'body_bounds': [-10000.0, 10000.0],
    'body_normalization': 'embedded-TRAIN-affine',
    'goal': [1.0, 0.0],
    'invalid_body': 'unavailable-no-inference',
  };

  /// Call with the actor's copied state at the capture tick, before awaiting GPU.
  List<double> ownBody({
    required PhysicsPose pose,
    required Vec3 velocity,
    required Vec3 angularVelocity,
  }) {
    final local = _local(pose.rotation, velocity);
    final values = [
      local.x,
      local.y,
      local.z,
      angularVelocity.y,
      pose.position.y,
      1.0,
      0.0,
      1.0,
    ];
    if (!velocity.isFinite ||
        !angularVelocity.isFinite ||
        values.any((v) => !v.isFinite || v.abs() > 10000)) {
      throw ArgumentError('Own-body features exceed the visual schema bounds.');
    }
    return List.unmodifiable(values);
  }

  /// Selects actual A6 RGB or RGBDV planes without a second affine transform.
  MlTensor compose(MlTensor captured, {required List<double> ownBody}) {
    final shape = [1, camera.channels, camera.height, camera.width];
    if (captured.dtype != MlDtype.float32 ||
        captured.shape.length != shape.length ||
        List.generate(
          shape.length,
          (i) => i,
        ).any((i) => captured.shape[i] != shape[i]) ||
        ownBody.length != bodyWidth ||
        ownBody.any((v) => !v.isFinite || v.abs() > 10000) ||
        ownBody[5] != 1 ||
        ownBody[6] != 0) {
      throw ArgumentError('Visual camera or own-body ABI differs.');
    }
    if (ownBody[7] != 1) {
      throw StateError('Own-body observation is unavailable.');
    }
    final pixels = captured.float32Values;
    if (pixels.any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw StateError('Normalized native camera planes are unavailable.');
    }
    final count = camera.width * camera.height;
    if (camera.depth) {
      for (var i = 0; i < count; i++) {
        final valid = pixels[count * 4 + i];
        if (valid != 0 && valid != 1 ||
            valid == 0 && pixels[count * 3 + i] != 0) {
          throw StateError('Native depth and validity planes disagree.');
        }
      }
    }
    final values = Float32List(width);
    values.setRange(0, imageWidth, pixels, mode == 'depth' ? count * 3 : 0);
    values.setRange(imageWidth, width, ownBody);
    return MlTensor.float32([1, width], values);
  }
}
