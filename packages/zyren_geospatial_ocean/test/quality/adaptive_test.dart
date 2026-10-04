import 'package:test/test.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

void main() {
  test(
    'adaptation is opt in and unavailable measurements cannot count as fast frames',
    () {
      final disabled = OceanAdaptivePolicy();
      final active = OceanAdaptivePolicy(
        enabled: true,
        minimumDwell: const Duration(milliseconds: 100),
        minimumSamples: 3,
        smoothing: 1,
      );
      for (var i = 0; i < 100; i++) {
        expect(
          disabled.observe(
            current: OceanRenderQuality.high,
            elapsed: Duration(seconds: i),
            frameMilliseconds: 100,
          ),
          isNull,
        );
        expect(
          active.observe(
            current: OceanRenderQuality.high,
            elapsed: Duration(seconds: i),
            frameMilliseconds: null,
          ),
          isNull,
        );
      }
      expect(active.smoothedMilliseconds, isNull);
    },
  );
  test(
    'deterministic pressure traces enforce sustained hysteresis, dwell and permitted range',
    () {
      final policy = OceanAdaptivePolicy(
        enabled: true,
        targetMilliseconds: 16,
        hysteresis: .2,
        minimumDwell: const Duration(milliseconds: 100),
        minimumSamples: 3,
        smoothing: 1,
        minimum: OceanRenderQuality.medium,
        maximum: OceanRenderQuality.high,
      );
      OceanRenderQuality? sample(
        int time,
        double? milliseconds,
        OceanRenderQuality current,
      ) => policy.observe(
        current: current,
        elapsed: Duration(milliseconds: time),
        frameMilliseconds: milliseconds,
      );
      expect(sample(0, 30, OceanRenderQuality.high), isNull);
      expect(sample(50, 30, OceanRenderQuality.high), isNull);
      expect(
        sample(100, 30, OceanRenderQuality.high),
        OceanRenderQuality.medium,
      );
      expect(sample(150, 30, OceanRenderQuality.medium), isNull);
      expect(sample(200, 10, OceanRenderQuality.medium), isNull);
      expect(sample(250, null, OceanRenderQuality.medium), isNull);
      expect(sample(300, 10, OceanRenderQuality.medium), isNull);
      expect(sample(350, 10, OceanRenderQuality.medium), isNull);
      expect(
        sample(400, 10, OceanRenderQuality.medium),
        OceanRenderQuality.high,
      );
      for (var time = 450; time <= 3000; time += 50) {
        expect(
          sample(time, time % 100 == 0 ? 15 : 18, OceanRenderQuality.high),
          isNull,
        );
      }
      expect(
        () => sample(100, 16, OceanRenderQuality.high),
        throwsArgumentError,
      );
      expect(
        () => sample(3100, double.nan, OceanRenderQuality.high),
        throwsArgumentError,
      );
      policy.reset();
      expect(sample(0, 30, OceanRenderQuality.high), isNull);
    },
  );
}
