/// Per-component numerical envelopes relative to canonical coefficients.
/// These exclude physical-model error.
final class OceanFieldError {
  final double height, displacement, slope, displacementGradient, velocity;
  const OceanFieldError(
    this.height,
    this.displacement,
    this.slope,
    this.displacementGradient,
    this.velocity,
  );
}
