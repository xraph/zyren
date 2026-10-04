import 'dart:math' as math;

enum OceanReflectionMode { disabled, environment, screenSpace, planar }

/// Screen-space work is bounded by pixelBudget * (stepLimit + 5) depth probes.
/// Large views reduce actual ray steps; inspect effectiveSteps for that view.
final class OceanReflectionSettings {
  final OceanReflectionMode mode;
  final int stepLimit, pixelBudget;
  final double confidenceFade, maximumDistanceMetres, thicknessMetres;
  OceanReflectionSettings({
    this.mode = OceanReflectionMode.screenSpace,
    this.stepLimit = 32,
    this.pixelBudget = 2073600,
    this.confidenceFade = .08,
    this.maximumDistanceMetres = 200,
    this.thicknessMetres = .3,
  }) {
    if (mode == OceanReflectionMode.planar) {
      throw UnsupportedError(
        'Planar water reflections require a native secondary-view lease.',
      );
    }
    if (stepLimit < 1 ||
        stepLimit > 64 ||
        pixelBudget < 1 ||
        pixelBudget > 16777216 ||
        !confidenceFade.isFinite ||
        confidenceFade <= 0 ||
        confidenceFade > .5 ||
        !maximumDistanceMetres.isFinite ||
        maximumDistanceMetres <= 0 ||
        maximumDistanceMetres > 1e5 ||
        !thicknessMetres.isFinite ||
        thicknessMetres <= 0 ||
        thicknessMetres > 100) {
      throw ArgumentError('Invalid water reflection bounds.');
    }
  }
  int effectiveSteps(int width, int height) {
    if (width < 1 || height < 1) {
      throw ArgumentError('Invalid reflection viewport.');
    }
    if (mode != OceanReflectionMode.screenSpace) return 0;
    return math.max(
      0,
      math.min(
        stepLimit,
        (pixelBudget * (stepLimit + 5)) ~/ (width * height) - 5,
      ),
    );
  }
}
