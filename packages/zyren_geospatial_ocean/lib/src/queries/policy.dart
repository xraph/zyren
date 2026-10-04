import 'dart:math' as math;

/// Strict physical sampling admission. No visual quality setting changes these limits.
final class OceanQueryPolicy {
  final int maxSamples, maxIterations, maxModeEvaluations, maxDistinctTimes;
  final Duration maxAge;
  final double maxHeightErrorMetres,
      maxNormalErrorRadians,
      maxVelocityErrorMetresPerSecond;
  OceanQueryPolicy({
    this.maxSamples = 256,
    this.maxAge = Duration.zero,
    this.maxHeightErrorMetres = .01,
    this.maxNormalErrorRadians = math.pi / 360,
    this.maxVelocityErrorMetresPerSecond = .1,
    this.maxIterations = 12,
    this.maxModeEvaluations = 33554432,
    this.maxDistinctTimes = 8,
  }) {
    if (maxSamples < 1 ||
        maxSamples > 4096 ||
        maxIterations < 1 ||
        maxIterations > 32 ||
        maxModeEvaluations < 1 ||
        maxModeEvaluations > 134217728 ||
        maxDistinctTimes < 1 ||
        maxDistinctTimes > 8 ||
        maxAge.isNegative ||
        maxAge > const Duration(days: 1) ||
        !maxHeightErrorMetres.isFinite ||
        maxHeightErrorMetres < 1e-9 ||
        maxHeightErrorMetres > 1000 ||
        !maxNormalErrorRadians.isFinite ||
        maxNormalErrorRadians <= 0 ||
        maxNormalErrorRadians > math.pi / 2 ||
        !maxVelocityErrorMetresPerSecond.isFinite ||
        maxVelocityErrorMetresPerSecond <= 0 ||
        maxVelocityErrorMetresPerSecond > 1000) {
      throw ArgumentError('Invalid bounded physical ocean query policy.');
    }
  }
}
