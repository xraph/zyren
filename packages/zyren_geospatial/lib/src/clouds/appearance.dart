/// Source cloud lighting, two-lobe phase, powder and exponential haze controls.
/// Values are linear; cloud layers and absorption live in CloudParameters.
final class CloudAppearance {
  final double skyLightScale, groundBounceScale, powderScale, powderExponent;
  final double hazeDensityScale,
      hazeExponent,
      hazeScatteringCoefficient,
      hazeAbsorptionCoefficient;
  final double scatterAnisotropy1,
      scatterAnisotropy2,
      scatterAnisotropyMix,
      maxShadowFilterRadius;
  CloudAppearance({
    this.skyLightScale = 1,
    this.groundBounceScale = 1,
    this.powderScale = .8,
    this.powderExponent = 150,
    this.hazeDensityScale = 3e-5,
    this.hazeExponent = 1e-3,
    this.hazeScatteringCoefficient = .9,
    this.hazeAbsorptionCoefficient = .5,
    this.scatterAnisotropy1 = .7,
    this.scatterAnisotropy2 = -.2,
    this.scatterAnisotropyMix = .5,
    this.maxShadowFilterRadius = 6,
  }) {
    void range(double value, double low, double high, String name) {
      if (!value.isFinite || value < low || value > high) {
        throw ArgumentError.value(value, name, 'Expected $low through $high.');
      }
    }

    range(skyLightScale, 0, 100, 'skyLightScale');
    range(groundBounceScale, 0, 100, 'groundBounceScale');
    range(powderScale, 0, 1, 'powderScale');
    range(powderExponent, 0, 10000, 'powderExponent');
    range(hazeDensityScale, 0, 1, 'hazeDensityScale');
    range(hazeExponent, 1e-9, 1, 'hazeExponent');
    range(hazeScatteringCoefficient, 0, 100, 'hazeScatteringCoefficient');
    range(hazeAbsorptionCoefficient, 0, 100, 'hazeAbsorptionCoefficient');
    range(scatterAnisotropy1, -.999, .999, 'scatterAnisotropy1');
    range(scatterAnisotropy2, -.999, .999, 'scatterAnisotropy2');
    range(scatterAnisotropyMix, 0, 1, 'scatterAnisotropyMix');
    range(maxShadowFilterRadius, 0, 32, 'maxShadowFilterRadius');
  }
}
