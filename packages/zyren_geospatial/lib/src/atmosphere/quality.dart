/// A bounded layout retaining the source quadrature and four scattering orders.
enum AtmosphereQuality {
  balanced(256, 64, 64, 16, 24, 64, 24, 8);

  final int transmittanceWidth,
      transmittanceHeight,
      irradianceWidth,
      irradianceHeight;
  final int radiusSize, viewSize, sunSize, angleSize;
  const AtmosphereQuality(
    this.transmittanceWidth,
    this.transmittanceHeight,
    this.irradianceWidth,
    this.irradianceHeight,
    this.radiusSize,
    this.viewSize,
    this.sunSize,
    this.angleSize,
  );
  int get scatteringWidth => sunSize * angleSize;
  int get scatteringTexels => scatteringWidth * viewSize * radiusSize;
  int get residentBytes =>
      16 *
      (transmittanceWidth * transmittanceHeight +
          irradianceWidth * irradianceHeight +
          3 * scatteringTexels);
  String get key => 'bruneton-rgb-v1/$name/rgba32float/orders4/500-50-16-32';
}

/// Immutable table dimensions. Imported assets use the original source grid.
final class AtmosphereLutDimensions {
  final int transmittanceWidth,
      transmittanceHeight,
      irradianceWidth,
      irradianceHeight;
  final int radiusSize, viewSize, sunSize, angleSize;
  const AtmosphereLutDimensions._(
    this.transmittanceWidth,
    this.transmittanceHeight,
    this.irradianceWidth,
    this.irradianceHeight,
    this.radiusSize,
    this.viewSize,
    this.sunSize,
    this.angleSize,
  );
  static const source = AtmosphereLutDimensions._(
    256,
    64,
    64,
    16,
    32,
    128,
    32,
    8,
  );
  factory AtmosphereLutDimensions.generated(AtmosphereQuality quality) =>
      AtmosphereLutDimensions._(
        quality.transmittanceWidth,
        quality.transmittanceHeight,
        quality.irradianceWidth,
        quality.irradianceHeight,
        quality.radiusSize,
        quality.viewSize,
        quality.sunSize,
        quality.angleSize,
      );
}
