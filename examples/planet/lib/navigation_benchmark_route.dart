import 'dart:math' as math;

const navigationPhases = ['stationary', 'rotate', 'drag', 'zoom', 'reversal'];
const navigationPhaseDurationUs = 12000000;
const navigationReversalUs = 6000000;

bool navigationAdaptiveClouds(String variant) => switch (variant) {
  'auto' || 'shadowsOff' || 'sparse' => true,
  'low' || 'medium' || 'high' => false,
  _ => throw ArgumentError.value(variant, 'variant'),
};

/// A bounded orbit with a velocity sign change at six seconds.
/// The other moving phases retain the established smooth sine trajectory.
double navigationWave(String phase, int elapsedUs) {
  final t = elapsedUs.clamp(0, navigationPhaseDurationUs);
  if (phase == 'stationary') return 0;
  if (phase == 'reversal') {
    return t <= navigationReversalUs
        ? t / navigationReversalUs
        : (navigationPhaseDurationUs - t) / navigationReversalUs;
  }
  return math.sin(2 * math.pi * t / navigationPhaseDurationUs);
}
