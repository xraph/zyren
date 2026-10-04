/// Work and stability limits for the visual shallow-wave interaction grid.
final class OceanInteractionSettings {
  final int resolution, maxSubsteps, absorbingWidthCells;
  final double extentMetres,
      waveSpeed,
      damping,
      boundaryDamping,
      courantLimit,
      maxDisplacementMetres,
      foamLifetimeSeconds,
      foamGain;
  OceanInteractionSettings({
    this.resolution = 128,
    this.extentMetres = 64,
    this.waveSpeed = 2,
    this.damping = .4,
    this.boundaryDamping = 2,
    this.courantLimit = .9,
    this.maxSubsteps = 16,
    this.absorbingWidthCells = 8,
    this.maxDisplacementMetres = .5,
    this.foamLifetimeSeconds = 5,
    this.foamGain = .5,
  }) {
    if (resolution < 16 ||
        resolution > 512 ||
        resolution & (resolution - 1) != 0 ||
        maxSubsteps < 1 ||
        maxSubsteps > 32 ||
        absorbingWidthCells < 1 ||
        absorbingWidthCells * 2 >= resolution ||
        !extentMetres.isFinite ||
        extentMetres < 4 ||
        extentMetres > 4096 ||
        !waveSpeed.isFinite ||
        waveSpeed <= 0 ||
        waveSpeed > 100 ||
        !damping.isFinite ||
        damping < 0 ||
        damping > 100 ||
        !boundaryDamping.isFinite ||
        boundaryDamping < 0 ||
        boundaryDamping > 100 ||
        !courantLimit.isFinite ||
        courantLimit <= 0 ||
        courantLimit > 1 ||
        !maxDisplacementMetres.isFinite ||
        maxDisplacementMetres <= 0 ||
        maxDisplacementMetres > 10 ||
        !foamLifetimeSeconds.isFinite ||
        foamLifetimeSeconds <= 0 ||
        foamLifetimeSeconds > 120 ||
        !foamGain.isFinite ||
        foamGain < 0 ||
        foamGain > 100) {
      throw ArgumentError('Invalid bounded ocean interaction settings.');
    }
  }
  double get cellMetres => extentMetres / (resolution - 1);
  int substepsFor(int hz) {
    if (hz < 1 || hz > 1000000) {
      throw ArgumentError('Invalid interaction tick rate.');
    }
    for (var steps = 1; steps <= maxSubsteps; steps++) {
      final dt = 1 / (hz * steps), lambda = waveSpeed * dt / cellMetres;
      // Fourier stability of the actual damped five-point recurrence, including
      // its strongest absorbing boundary: 2 lambda² + damping*dt/2 <= 1.
      if (2 * lambda * lambda + (damping + boundaryDamping) * dt / 2 <=
          courantLimit) {
        return steps;
      }
    }
    throw ArgumentError(
      'Interaction grid cannot meet CFL within its substep budget.',
    );
  }
}
