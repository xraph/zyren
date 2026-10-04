import 'dart:math' as math;
import 'package:zyren/zyren.dart';

void validateOceanRadiance(Vec3 value, String name) {
  if (!value.isFinite ||
      value.x < 0 ||
      value.y < 0 ||
      value.z < 0 ||
      value.x > 65504 ||
      value.y > 65504 ||
      value.z > 65504) {
    throw ArgumentError('$name requires finite nonnegative RGB up to 65504.');
  }
}

/// Homogeneous Beer-Lambert attenuation. Coefficients use inverse metres.
Vec3 waterTransmittance(Vec3 extinction, double metres) {
  validateOceanRadiance(extinction, 'Extinction');
  if (!metres.isFinite || metres < 0) {
    throw ArgumentError('Water path length must be finite and nonnegative.');
  }
  return Vec3(
    math.exp(-extinction.x * metres),
    math.exp(-extinction.y * metres),
    math.exp(-extinction.z * metres),
  );
}

/// Unpolarized dielectric power reflectance. The normal faces the incident ray;
/// cosine is nonnegative, and the caller declares both incident/transmitted IORs.
double waterFresnel(double cosine, double fromIor, double toIor) {
  if (!cosine.isFinite ||
      cosine < 0 ||
      cosine > 1 ||
      !fromIor.isFinite ||
      fromIor < .01 ||
      fromIor > 10 ||
      !toIor.isFinite ||
      toIor < .01 ||
      toIor > 10) {
    throw ArgumentError('Invalid dielectric angle or refractive index.');
  }
  if (fromIor == toIor) return 0;
  if (cosine == 0) return 1;
  final eta = fromIor / toIor;
  final sinSquared = eta * eta * (1 - cosine * cosine);
  if (sinSquared >= 1) return 1;
  final transmitted = math.sqrt(1 - sinSquared);
  final s =
      (fromIor * cosine - toIor * transmitted) /
      (fromIor * cosine + toIor * transmitted);
  final p =
      (toIor * cosine - fromIor * transmitted) /
      (toIor * cosine + fromIor * transmitted);
  return (s * s + p * p) * .5;
}

/// RGB homogeneous water approximation. Absorption and scattering use m^-1.
/// This describes the medium, independent of the sea state's physical density.
final class OceanOptics {
  final Vec3 absorptionPerMetre, scatteringPerMetre;
  final double indexOfRefraction, roughness, maximumPathMetres;
  OceanOptics({
    this.absorptionPerMetre = const Vec3(.35, .06, .025),
    this.scatteringPerMetre = const Vec3(.008, .018, .022),
    this.indexOfRefraction = 1.333,
    this.roughness = .08,
    this.maximumPathMetres = 250,
  }) {
    validateOceanRadiance(absorptionPerMetre, 'Absorption');
    validateOceanRadiance(scatteringPerMetre, 'Scattering');
    validateOceanRadiance(extinction, 'Extinction');
    if (!indexOfRefraction.isFinite ||
        indexOfRefraction < 1 ||
        indexOfRefraction > 3 ||
        !roughness.isFinite ||
        roughness < 0 ||
        roughness > 1 ||
        !maximumPathMetres.isFinite ||
        maximumPathMetres <= 0 ||
        maximumPathMetres > 1e5) {
      throw ArgumentError('Invalid ocean optics settings.');
    }
  }
  Vec3 get extinction => absorptionPerMetre + scatteringPerMetre;

  /// Single homogeneous source term, with isotropic incident radiance supplied
  /// by the caller. Multiple scattering and light-path shadowing are excluded.
  Vec3 integrate(Vec3 behind, Vec3 incident, double metres) {
    validateOceanRadiance(behind, 'Background radiance');
    validateOceanRadiance(incident, 'Incident radiance');
    final t = waterTransmittance(extinction, metres);
    double channel(double b, double light, double trans, double s, double e) =>
        b * trans + (e == 0 ? 0 : light * s / e * (1 - trans));
    return Vec3(
      channel(behind.x, incident.x, t.x, scatteringPerMetre.x, extinction.x),
      channel(behind.y, incident.y, t.y, scatteringPerMetre.y, extinction.y),
      channel(behind.z, incident.z, t.z, scatteringPerMetre.z, extinction.z),
    );
  }
}
