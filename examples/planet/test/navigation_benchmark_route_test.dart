import 'package:flutter_test/flutter_test.dart';
import 'package:planet/navigation_benchmark_route.dart';

void main() {
  test('device defaults adapt and named presets stay fixed', () {
    for (final variant in ['auto', 'shadowsOff', 'sparse']) {
      expect(navigationAdaptiveClouds(variant), isTrue);
    }
    for (final variant in ['low', 'medium', 'high']) {
      expect(navigationAdaptiveClouds(variant), isFalse);
    }
    expect(() => navigationAdaptiveClouds('unknown'), throwsArgumentError);
  });
  test(
    'fifth phase reverses velocity sharply at six seconds within bounds',
    () {
      expect(navigationPhases.length, 5);
      expect(navigationPhases.last, 'reversal');
      expect(navigationWave('reversal', 0), 0);
      expect(navigationWave('reversal', navigationReversalUs), 1);
      expect(navigationWave('reversal', navigationPhaseDurationUs), 0);
      final before = navigationWave('reversal', navigationReversalUs - 1000);
      final after = navigationWave('reversal', navigationReversalUs + 1000);
      expect(before, closeTo(after, 1e-12));
      expect(before, lessThan(1));
      for (var us = -1000000; us <= 13000000; us += 100000) {
        expect(navigationWave('reversal', us), inInclusiveRange(0, 1));
      }
    },
  );
}
