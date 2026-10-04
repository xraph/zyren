import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

void main() {
  test(
    'opaque capture scale is bounded and survives render settings copies',
    () {
      expect(RenderSettings().opaqueCaptureScale, 1);
      for (final scale in [.5, .75, 1.0]) {
        final settings = RenderSettings(opaqueCaptureScale: scale);
        expect(settings.copyWith(exposure: 2).opaqueCaptureScale, scale);
        expect(settings.copyWith(opaqueCaptureScale: 1).opaqueCaptureScale, 1);
      }
      for (final invalid in [double.nan, double.infinity, 0.0, .49, 1.01]) {
        expect(
          () => RenderSettings(opaqueCaptureScale: invalid),
          throwsArgumentError,
        );
      }
    },
  );
}
