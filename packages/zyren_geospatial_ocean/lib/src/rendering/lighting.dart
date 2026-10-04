import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'optics.dart';

/// Directions use ECEF, matching fixed wave charts. RGB values are linear HDR.
/// Supply atmosphere tables or a convolved native environment for scene lighting;
/// the standalone sky/ground colors are an explicit hemispherical approximation.
final class OceanLighting {
  final Vec3 sunDirectionEcef, sunIrradiance, skyRadiance, groundRadiance;
  final AtmosphereLuts? atmosphere;
  final VolumeEnvironmentMap? environment;
  OceanLighting({
    this.sunDirectionEcef = const Vec3(1, 0, 1),
    this.sunIrradiance = const Vec3(4, 3.8, 3.5),
    this.skyRadiance = const Vec3(.15, .3, .5),
    this.groundRadiance = const Vec3(.015, .02, .025),
    this.atmosphere,
    this.environment,
  }) {
    if (!sunDirectionEcef.isFinite ||
        sunDirectionEcef.length2 < 1e-20 ||
        !sunDirectionEcef.length2.isFinite) {
      throw ArgumentError('A finite nonzero sunlight direction is required.');
    }
    for (final v in [sunIrradiance, skyRadiance, groundRadiance]) {
      validateOceanRadiance(v, 'Ocean lighting');
    }
    if (atmosphere != null && environment != null) {
      throw ArgumentError('Select one environment lighting source.');
    }
    if ((atmosphere?.isClosed ?? false) || (environment?.isClosed ?? false)) {
      throw StateError('Ocean lighting resources have closed.');
    }
  }

  /// Reuses the shared atmosphere's precomputed lighting, including night and
  /// horizon attenuation. The full LUT option additionally supplies directional
  /// reflected sky radiance in the native water shader.
  factory OceanLighting.fromAtmosphereSample(
    AtmosphereLightSample sample, {
    required Vec3 sunDirectionEcef,
    AtmosphereLuts? atmosphere,
  }) => OceanLighting(
    sunDirectionEcef: sunDirectionEcef,
    sunIrradiance: sample.sunIrradiance,
    skyRadiance: sample.skyIrradiance / math.pi,
    atmosphere: atmosphere,
  );
}
