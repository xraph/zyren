import 'package:flutter_test/flutter_test.dart';
import 'package:planet/navigation_benchmark_stats.dart';

void main() {
  test('retains native phases and nullable pass costs for every phase', () {
    final stats = summarizeNavigationFrames([
      {
        'atUs': 1,
        'profile': {
          'status': 'complete',
          'cpuPrepareNs': 2000000,
          'cpuEncodeNs': 1000000,
          'cpuCompletionWaitNs': 4000000,
          'submissionCount': 3,
          'passes': {
            'scene': {'executed': true, 'gpuTimeNs': 3000000},
            'shadows': {'executed': true, 'gpuTimeNs': null},
          },
        },
      },
      {
        'atUs': 10001,
        'profile': {
          'status': 'complete',
          'cpuPrepareNs': 6000000,
          'cpuEncodeNs': 3000000,
          'cpuCompletionWaitNs': 8000000,
          'submissionCount': 1,
          'passes': {
            'scene': {'executed': true, 'gpuTimeNs': 7000000},
            'shadows': {'executed': false, 'gpuTimeNs': null},
          },
        },
      },
    ]);
    expect(stats['nativeProfileCount'], 2);
    expect((stats['nativePrepareMs'] as Map)['max'], 6);
    expect((stats['nativeEncodeMs'] as Map)['count'], 2);
    expect((stats['nativeWaitMs'] as Map)['max'], 8);
    expect((stats['submissionCount'] as Map)['max'], 3);
    final passes = stats['passes'] as Map;
    expect((passes['scene'] as Map)['count'], 2);
    expect(passes['shadows'], isNull);
  });

  test(
    'failed profiles stay excluded and resource deltas preserve unknown GPU work',
    () {
      final stats = summarizeNavigationFrames([
        {
          'atUs': 0,
          'profile': {
            'status': 'complete',
            'resources': {'submissionCount': 4, 'gpuTimeNs': null},
          },
        },
        {
          'atUs': 10000,
          'profile': {'status': 'failed', 'cpuPrepareNs': 1000000000},
        },
        {
          'atUs': 20000,
          'profile': {
            'status': 'complete',
            'resources': {'submissionCount': 9, 'gpuTimeNs': null},
          },
        },
      ]);
      expect(stats['nativeProfileCount'], 2);
      expect(stats['nativeProfileMissingFrames'], 1);
      expect(stats['nativePrepareMs'], isNull);
      expect((stats['resourcePhaseDelta'] as Map)['submissionCount'], 5);
      expect((stats['resourcePhaseDelta'] as Map)['gpuTimeNs'], isNull);
    },
  );

  test('frame rate uses presentation span and includes stalls', () {
    final stats = summarizeNavigationFrames([
      {'atUs': 1000000, 'buildUs': 1000, 'gpuUs': null},
      {'atUs': 1010000, 'buildUs': 2000, 'gpuUs': 3000},
      {'atUs': 1020000, 'buildUs': 3000, 'gpuUs': 4000},
      {'atUs': 1120000, 'buildUs': 4000, 'gpuUs': null},
    ]);
    expect(stats['presentedFps'], 25);
    expect(stats['intervalMs'], {
      'count': 3,
      'median': 10.0,
      'p95': 100.0,
      'p99': 100.0,
      'max': 100.0,
    });
    expect(stats['over33ms'], 1);
    expect((stats['gpuMs'] as Map)['count'], 2);
    expect((stats['gpuMs'] as Map)['max'], 4);
  });

  test('missing frames and GPU timings stay unknown', () {
    final stats = summarizeNavigationFrames([
      {'atUs': 9000000},
    ]);
    expect(stats['presentedFps'], isNull);
    expect(stats['intervalMs'], isNull);
    expect(stats['gpuMs'], isNull);
    expect(summarizeNavigationFrames([])['presentedFps'], isNull);
  });
}
