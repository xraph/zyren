import 'settings.dart';

/// Opt-in recommendations from measured presentation cost. The caller still
/// admits and publishes a candidate; rejection cannot change the current profile.
/// This policy owns no animation, query or simulation clock.
final class OceanAdaptivePolicy {
  final bool enabled;
  final double targetMilliseconds, hysteresis, smoothing;
  final Duration minimumDwell;
  final int minimumSamples;
  final OceanRenderQuality minimum, maximum;
  Duration? _lastObservation, _directionSince, _lastRecommendation;
  double? _smoothed;
  int _direction = 0, _samples = 0;
  OceanAdaptivePolicy({
    this.enabled = false,
    this.targetMilliseconds = 1000 / 60,
    this.hysteresis = .2,
    this.smoothing = .1,
    this.minimumDwell = const Duration(seconds: 5),
    this.minimumSamples = 30,
    this.minimum = OceanRenderQuality.low,
    this.maximum = OceanRenderQuality.ultra,
  }) {
    if (!targetMilliseconds.isFinite ||
        targetMilliseconds <= 0 ||
        targetMilliseconds > 1000 ||
        !hysteresis.isFinite ||
        hysteresis <= 0 ||
        hysteresis >= 1 ||
        !smoothing.isFinite ||
        smoothing <= 0 ||
        smoothing > 1 ||
        minimumDwell < const Duration(milliseconds: 100) ||
        minimumDwell > const Duration(minutes: 10) ||
        minimumSamples < 2 ||
        minimumSamples > 10000 ||
        minimum.index > maximum.index) {
      throw ArgumentError('Invalid adaptive ocean policy.');
    }
  }
  double? get smoothedMilliseconds => _smoothed;

  /// Supply a consistent measured cost, such as whole-frame GPU milliseconds.
  /// Null means unavailable, resets the pressure streak and never counts as zero.
  /// Time must be monotonic. Recommendations move one preset at a time and are
  /// separated by minimumDwell, even when the last recommendation was rejected.
  OceanRenderQuality? observe({
    required OceanRenderQuality current,
    required Duration elapsed,
    required double? frameMilliseconds,
  }) {
    if (elapsed.isNegative ||
        (_lastObservation != null && elapsed < _lastObservation!) ||
        (frameMilliseconds != null &&
            (!frameMilliseconds.isFinite ||
                frameMilliseconds <= 0 ||
                frameMilliseconds > 60000)) ||
        current.index < minimum.index ||
        current.index > maximum.index) {
      throw ArgumentError('Invalid or nonmonotonic ocean timing observation.');
    }
    _lastObservation = elapsed;
    if (!enabled || frameMilliseconds == null) {
      _smoothed = null;
      _directionSince = null;
      _direction = 0;
      _samples = 0;
      return null;
    }
    final measured = _smoothed == null
        ? frameMilliseconds
        : _smoothed! * (1 - smoothing) + frameMilliseconds * smoothing;
    _smoothed = measured;
    final direction = measured > targetMilliseconds * (1 + hysteresis)
        ? -1
        : measured < targetMilliseconds * (1 - hysteresis)
        ? 1
        : 0;
    if (direction == 0) {
      _direction = 0;
      _directionSince = null;
      _samples = 0;
      return null;
    }
    if (direction != _direction) {
      _direction = direction;
      _directionSince = elapsed;
      _samples = 0;
    }
    _samples++;
    if (_samples < minimumSamples ||
        elapsed - _directionSince! < minimumDwell ||
        (_lastRecommendation != null &&
            elapsed - _lastRecommendation! < minimumDwell)) {
      return null;
    }
    final target = current.index + direction;
    if (target < minimum.index || target > maximum.index) return null;
    _lastRecommendation = elapsed;
    _directionSince = elapsed;
    _samples = 0;
    return OceanRenderQuality.values[target];
  }

  void reset() {
    _lastObservation = null;
    _directionSince = null;
    _lastRecommendation = null;
    _smoothed = null;
    _direction = 0;
    _samples = 0;
  }
}
