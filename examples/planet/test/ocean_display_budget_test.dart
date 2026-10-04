import 'package:test/test.dart';
import 'package:planet/ocean/scenes/display_budget.dart';

void main() {
  test('native device and rotated viewports stay inside capture budgets', () {
    for (final (width, height, dpr) in [
      (402.0, 778.0, 3.0),
      (1032.0, 1348.0, 2.0),
      (448.0, 928.0, 2.5),
      (1440.0, 900.0, 2.0),
      (320.0, 568.0, 1.0),
    ]) {
      for (final budget in [1280 * 720, 1920 * 1080]) {
        for (final (w, h) in [(width, height), (height, width)]) {
          final scale = oceanResolutionScale(
            width: w,
            height: h,
            devicePixelRatio: dpr,
            maxPixels: budget,
          );
          expect(scale, inExclusiveRange(0, 1.00000001));
          final physicalWidth = (w * dpr * scale).round();
          final physicalHeight = (h * dpr * scale).round();
          expect(physicalWidth * physicalHeight, lessThanOrEqualTo(budget));
          expect(physicalWidth / physicalHeight, closeTo(w / h, .005));
        }
      }
    }
  });

  test('a viewport already inside the budget retains native resolution', () {
    expect(
      oceanResolutionScale(
        width: 320,
        height: 568,
        devicePixelRatio: 1,
        maxPixels: 1280 * 720,
      ),
      1,
    );
  });
}
