import 'dart:typed_data';
import 'parameters.dart';
import 'appearance.dart';

Float32List cloudMediaUniforms(
  CloudParameters p,
  CloudAppearance a, {
  double elapsed = 0,
}) {
  if (!elapsed.isFinite || elapsed < 0 || elapsed > 1e9) {
    throw ArgumentError.value(elapsed, 'elapsed');
  }
  final layers = p.layers.layers, gaps = p.layers.gaps;
  return Float32List.fromList([
    for (final l in layers) l.altitude,
    for (final l in layers) l.altitude + l.height,
    for (final l in layers)
      l.height > 0 ? l.densityScale * p.densityMultiplier : 0,
    for (final l in layers) l.shapeAmount,
    for (final l in layers) l.shapeDetailAmount,
    for (final l in layers) l.weatherExponent,
    for (final l in layers) l.shapeAlteringBias,
    for (final l in layers) l.coverageFilterWidth,
    for (final l in layers) l.shadow && l.height > 0 ? 1 : 0,
    for (final l in layers) l.densityProfile.expTerm,
    for (final l in layers) l.densityProfile.exponent,
    for (final l in layers) l.densityProfile.linearTerm,
    for (final l in layers) l.densityProfile.constantTerm,
    ...gaps.map((v) => v.$1),
    p.layers.minimumAltitude,
    ...gaps.map((v) => v.$2),
    p.layers.maximumAltitude,
    p.localWeatherRepeat.$1,
    p.localWeatherRepeat.$2,
    p.localWeatherOffset.$1 + p.localWeatherVelocity.$1 * elapsed,
    p.localWeatherOffset.$2 + p.localWeatherVelocity.$2 * elapsed,
    ...p.shapeRepeat.storage,
    p.effectiveCoverage,
    ...(p.shapeOffset + p.shapeVelocity * elapsed).storage,
    p.scatteringCoefficient,
    ...p.shapeDetailRepeat.storage,
    p.absorptionCoefficient,
    ...(p.shapeDetailOffset + p.shapeDetailVelocity * elapsed).storage,
    p.turbulenceDisplacement,
    p.turbulenceRepeat.$1,
    p.turbulenceRepeat.$2,
    p.layers.shadowBottom,
    p.layers.shadowTop,
    for (final l in layers) l.channel.toDouble(),
    a.skyLightScale,
    a.groundBounceScale,
    a.powderScale,
    a.powderExponent,
    a.hazeDensityScale,
    a.hazeExponent,
    a.hazeScatteringCoefficient,
    a.hazeAbsorptionCoefficient,
    a.scatterAnisotropy1,
    a.scatterAnisotropy2,
    a.scatterAnisotropyMix,
    a.maxShadowFilterRadius,
  ]);
}
