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
  final profiles = [
    for (final frame in frames)
      if (frame['profile'] case final Map profile)
        if (profile['status'] == 'complete') profile,
  ];
  Map<String, Object?>? native(String key, [double divisor = 1000000]) =>
      _distribution([
        for (final profile in profiles)
          if (profile[key] case final num value) value / divisor,
      ]);
  final passNames = {
    for (final profile in profiles)
      if (profile['passes'] case final Map passes)
        ...passes.keys.cast<String>(),
  };
  // Resource deltas cover the interval between the first and last collected
  // profiles. Work before the first presentation is excluded.
  final firstResources = profiles.isEmpty
      ? null
      : profiles.first['resources'] as Map?;
  final lastResources = profiles.isEmpty
      ? null
      : profiles.last['resources'] as Map?;
  num? resourceDelta(String key) {
    final first = firstResources?[key], last = lastResources?[key];
    return first is num && last is num && last >= first ? last - first : null;
  }

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
    'tileAndHistory': {
      for (final key in [
        'loading',
        'visible',
        'selected',
        'displayed',
        'prefetched',
        'prefetchBytes',
        'tileBytes',
        'cloudHistory',
      ])
        key: _distribution([
          for (final frame in frames)
            if (frame[key] case final num value) value.toDouble(),
        ]),
    },
    'uploadBacklogBytes': _distribution([
      for (final frame in frames)
        if (frame['admission'] case final Map admission)
          if (admission['uploadBacklogBytes'] case final num value)
            value.toDouble(),
    ]),
    'nativeProfileCount': profiles.length,
    'nativeProfileMissingFrames': frames.length - profiles.length,
    'resourcePhaseDelta': {
      for (final key in [
        'submissionCount',
        'graphSubmissionCount',
        'cpuCompletionWaitNs',
        'gpuTimeNs',
        'graphGpuTimeNs',
        'uploadedBytes',
      ])
        key: resourceDelta(key),
    },
    'nativePrepareMs': native('cpuPrepareNs'),
    'nativeEncodeMs': native('cpuEncodeNs'),
    'nativeWaitMs': native('cpuCompletionWaitNs'),
    'submissionCount': native('submissionCount', 1),
    'drawPreparationBuffers': native('drawPreparationBuffers', 1),
    'drawPreparationBindGroups': native('drawPreparationBindGroups', 1),
    'drawCacheReuses': native('drawCacheReuses', 1),
    'drawUniformReuses': native('drawUniformReuses', 1),
    'drawUniformWriteCalls': native('drawUniformWriteCalls', 1),
    'drawUniformWriteBytes': native('drawUniformWriteBytes', 1),
    'drawUniformSkippedWrites': native('drawUniformSkippedWrites', 1),
    'drawCacheEntries': native('drawCacheEntries', 1),
    'drawCacheUniformBytes': native('drawCacheUniformBytes', 1),
    'uploadBytes': native('uploadBytes', 1),
    'passes': {
      for (final name in passNames)
        name: _distribution([
          for (final profile in profiles)
            if (profile['passes'] case final Map passes)
              if (passes[name] case final Map pass)
                if (pass['gpuTimeNs'] case final num value) value / 1000000,
        ]),
    },
  };
}
