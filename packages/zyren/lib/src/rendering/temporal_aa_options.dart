/// Native temporal reconstruction, before post-processing and tone mapping.
/// Uses eight jitter phases and a per-view budget including retained motion data.
final class TemporalAAOptions {
  final double historyWeight, depthTolerance;
  final int maxBytes;
  TemporalAAOptions({
    this.historyWeight = .9,
    this.depthTolerance = .01,
    this.maxBytes = 128 * 1024 * 1024,
  }) {
    if (!historyWeight.isFinite ||
        historyWeight < 0 ||
        historyWeight >= 1 ||
        !depthTolerance.isFinite ||
        depthTolerance < 1e-5 ||
        depthTolerance > .1 ||
        maxBytes < 1 ||
        maxBytes > 256 * 1024 * 1024) {
      throw ArgumentError(
        'Temporal AA requires history weight [0,1), depth tolerance [1e-5,.1] and a budget up to 256 MiB.',
      );
    }
  }
}
