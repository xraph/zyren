import 'dart:math' as math;
import '../astronomy/celestial_directions.dart';
import 'appearance.dart';

/// Lunar irradiance relative to the Sun, with a Lambert-sphere phase.
double lunarIrradianceScale(
  CelestialDirections directions,
  AtmosphereAppearance appearance,
) {
  if (!appearance.moonLight || appearance.moonLightIntensity == 0) return 0;
  final angle = math.acos(
    (-directions.sunECEF.dot(directions.moonECEF)).clamp(-1.0, 1.0),
  );
  final phase =
      (math.sin(angle) + (math.pi - angle) * math.cos(angle)) / math.pi;
  return 2.5e-6 * phase * appearance.moonLightIntensity;
}
