import 'dart:math' as math;

Map<String, Object?>? _distribution(List<double> values) {
  if (values.isEmpty) return null;
  values.sort();
  double percentile(double fraction) =>
      values[math.max(0, (values.length * fraction).ceil() - 1)];
  return {
    'count': values.length,
    'median': percentile(.5),
    'p95': percentile(.95),
    'p99': percentile(.99),
    'max': values.last,
  };
}

/// Presentation pacing includes stalls, but excludes time before the first frame.
/// Missing GPU measurements stay null and do not become zero-cost samples.
Map<String, Object?> summarizeNavigationFrames(
  List<Map<String, Object?>> frames,
) {
  final intervals = <double>[
    for (var i = 1; i < frames.length; i++)
      ((frames[i]['atUs'] as int) - (frames[i - 1]['atUs'] as int)) / 1000,
  ];
  Map<String, Object?>? timing(String key) => _distribution([
    for (final frame in frames)
      if (frame[key] case final num value) value / 1000,
  ]);
  final span = intervals.fold<double>(0, (sum, value) => sum + value);
  return {
    'frames': frames.length,
    'spanMs': span,
    'presentedFps': span <= 0 ? null : intervals.length * 1000 / span,
    'intervalMs': _distribution(intervals),
    'over16_7ms': intervals.where((v) => v > 1000 / 60).length,
    'over33ms': intervals.where((v) => v > 1000 / 30).length,
    'over100ms': intervals.where((v) => v > 100).length,
    'buildMs': timing('buildUs'),
    'submitMs': timing('submitUs'),
    'gpuMs': timing('gpuUs'),
  };
}
