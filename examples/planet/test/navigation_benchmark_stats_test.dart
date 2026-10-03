import 'package:flutter_test/flutter_test.dart';
import 'package:planet/navigation_benchmark_stats.dart';

void main() {
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
