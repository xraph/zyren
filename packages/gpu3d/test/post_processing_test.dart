import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

void main() {
  test('bloom rejects nonfinite and out-of-range settings', () {
    for (final invalid in [double.nan, double.infinity, -1.0]) {
      expect(() => BloomOptions(threshold: invalid), throwsArgumentError);
      expect(() => BloomOptions(knee: invalid), throwsArgumentError);
      expect(() => BloomOptions(intensity: invalid), throwsArgumentError);
      expect(() => BloomOptions(radius: invalid), throwsArgumentError);
    }
    expect(() => BloomOptions(knee: 1.01), throwsArgumentError);
    expect(() => BloomOptions(intensity: 17), throwsArgumentError);
    expect(() => BloomOptions(radius: .49), throwsArgumentError);
    expect(() => BloomOptions(radius: 4.01), throwsArgumentError);
    expect(() => PostProcessing(maxIntermediateBytes: 0), throwsArgumentError);
  });
}
