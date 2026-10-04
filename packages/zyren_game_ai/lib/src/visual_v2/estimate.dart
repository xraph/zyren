part of '../../visual_v2.dart';

final class VisualTargetEstimate {
  final double lateral,
      forward,
      velocityLateral,
      velocityForward,
      positionSigma,
      velocitySigma,
      confidence,
      visibleProbability;
  const VisualTargetEstimate._(
    this.lateral,
    this.forward,
    this.velocityLateral,
    this.velocityForward,
    this.positionSigma,
    this.velocitySigma,
    this.confidence,
    this.visibleProbability,
  );
  bool get admitted =>
      confidence >= .9 && visibleProbability >= .9 && positionSigma <= .75;
}

final class VisualObstacleEstimate {
  final double lateral, forward, halfWidth, halfLength, sigma, confidence;
  const VisualObstacleEstimate._(
    this.lateral,
    this.forward,
    this.halfWidth,
    this.halfLength,
    this.sigma,
    this.confidence,
  );
}

final class VisualClearance {
  final double knownProbability, freeMetres;
  const VisualClearance._(this.knownProbability, this.freeMetres);
}

/// Closed 74-value ABI. Decode rejects excess, nonfinite and out-of-range data.
final class VisualEstimate {
  final List<double> values;
  final String profileHash;
  final VisualTargetEstimate target;
  final List<VisualObstacleEstimate> obstacles;
  final List<VisualClearance> clearance;
  VisualEstimate._(List<double> data, this.profileHash)
    : values = List.unmodifiable(data),
      target = VisualTargetEstimate._(
        data[0],
        data[1],
        data[2],
        data[3],
        data[4],
        data[5],
        data[6],
        data[7],
      ),
      obstacles = List.unmodifiable([
        for (var i = 8; i < 56; i += 6)
          VisualObstacleEstimate._(
            data[i],
            data[i + 1],
            data[i + 2],
            data[i + 3],
            data[i + 4],
            data[i + 5],
          ),
      ]),
      clearance = List.unmodifiable([
        for (var i = 56; i < 74; i += 2)
          VisualClearance._(data[i], data[i + 1]),
      ]);
  static final ActionSpec spec = ActionSpec(
    id: 'visual-estimate-v2',
    version: 2,
    continuous: [
      for (final pair in [
        ('target.lateralMetres', -40.0, 40.0),
        ('target.forwardMetres', 0.0, 40.0),
        ('target.velocityLateral', -5.0, 5.0),
        ('target.velocityForward', -5.0, 5.0),
        ('target.positionSigma', 0.0, 10.0),
        ('target.velocitySigma', 0.0, 5.0),
        ('target.confidence', 0.0, 1.0),
        ('target.visibleProbability', 0.0, 1.0),
      ])
        ObservationField(pair.$1, min: pair.$2, max: pair.$3),
      for (var i = 0; i < 8; i++) ...[
        ObservationField('obstacle.$i.lateralMetres', min: -40, max: 40),
        ObservationField('obstacle.$i.forwardMetres', min: 0, max: 40),
        ObservationField('obstacle.$i.halfWidth', min: 0, max: 20),
        ObservationField('obstacle.$i.halfLength', min: 0, max: 20),
        ObservationField('obstacle.$i.sigma', min: 0, max: 10),
        ObservationField('obstacle.$i.confidence', min: 0, max: 1),
      ],
      for (var i = 0; i < 9; i++) ...[
        ObservationField('clearance.$i.knownProbability', min: 0, max: 1),
        ObservationField('clearance.$i.freeMetres', min: 0, max: 40),
      ],
    ],
    fallbackContinuous: [
      0,
      0,
      0,
      0,
      10,
      5,
      0,
      0,
      for (var i = 0; i < 8; i++) ...[0, 0, 0, 0, 10, 0],
      for (var i = 0; i < 9; i++) ...[0, 0],
    ],
  );
  factory VisualEstimate.decode(
    List<double> values, {
    required VisualNavigationProfile profile,
  }) {
    if (!spec.accepts(values, const [])) {
      throw ArgumentError('Visual estimate differs from its bounded ABI.');
    }
    // A high-confidence visible estimate must fit the optical horizontal frustum.
    for (final item in [
      (values[0], values[1], values[6] >= .9 && values[7] >= .9),
      for (var i = 8; i < 56; i += 6)
        (values[i], values[i + 1], values[i + 5] >= .9),
    ]) {
      if (item.$3 &&
          (item.$2 < profile.camera.near ||
              math.sqrt(item.$1 * item.$1 + item.$2 * item.$2) > 40 ||
              math.atan2(item.$1.abs(), item.$2) >
                  profile.camera.fieldOfView / 2)) {
        throw ArgumentError(
          'Visible estimate lies outside captured projection.',
        );
      }
    }
    return VisualEstimate._(values, profile.hash);
  }
  factory VisualEstimate.unknown(VisualNavigationProfile profile) =>
      VisualEstimate.decode(spec.fallbackContinuous, profile: profile);
}

/// One retained goal sample, distinct from the generic entity belief store.
/// It has no semantic target handle and cannot resolve hidden world state.
final class VisualGoalBelief {
  final VisualCapturePose captured;
  final Vec3 position, velocity;
  final double positionSigma, velocitySigma;
  VisualGoalBelief._(this.captured, VisualTargetEstimate target)
    : position = captured.groundPoint(target.lateral, target.forward),
      velocity = captured.cameraRotation.rotate(
        Vec3(target.velocityLateral, 0, target.velocityForward),
      ),
      positionSigma = target.positionSigma,
      velocitySigma = target.velocitySigma;
  double sigmaAt(int tick) =>
      positionSigma +
      (tick - captured.captureTick) * (.001 + velocitySigma / 50);
  bool current(VisualCaptureIdentity identity, int tick) =>
      captured.identity == identity &&
      tick >= captured.captureTick &&
      tick - captured.captureTick <= 600 &&
      sigmaAt(tick) <= .75;
  Vec3 positionAt(int tick) =>
      position + velocity * ((tick - captured.captureTick) / 50);
  GameGoal? goalAt(VisualCaptureIdentity identity, int tick) =>
      current(identity, tick)
      ? GameGoal(
          id: 'visual-goal-v2',
          skill: 'follow-route',
          route: [positionAt(tick)],
        )
      : null;
}
