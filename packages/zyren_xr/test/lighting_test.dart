import 'package:test/test.dart';
import 'package:zyren_xr/zyren_xr.dart';
import 'fixtures.dart';

void main() {
  test(
    'native estimates use explicit units and stale input disables the light',
    () {
      final adapter = XrAmbientLighting(neutralIntensityLux: 400);
      final message = snapshotMessage();
      expect(adapter.update(XrSnapshot.fromMessage(message)), isTrue);
      expect(adapter.light.intensity, closeTo(360, 1e-9));
      final frame = message['frame'] as Map;
      frame['light'] = {
        'ambientIntensity': .5,
        'intensityUnit': 'relative-gamma',
        'colorTemperature': null,
        'colorCorrection': [1.0, 1.0, 1.0, .5],
      };
      expect(adapter.update(XrSnapshot.fromMessage(message)), isTrue);
      expect(adapter.light.intensity, closeTo(400, 1e-9));
      frame['light'] = {
        'ambientIntensity': .25,
        'intensityUnit': 'relative-gamma',
        'colorTemperature': null,
        'colorCorrection': [1.0, 1.0, 1.0, .25],
      };
      expect(adapter.update(XrSnapshot.fromMessage(message)), isTrue);
      expect(adapter.light.intensity, closeTo(87.055, .001));
      message['nativeTimestamp'] = 14.0;
      expect(adapter.update(XrSnapshot.fromMessage(message)), isFalse);
      expect(adapter.light.intensity, 0);
      message['nativeTimestamp'] = 12.1;
    frame.remove('light');
      expect(adapter.update(XrSnapshot.fromMessage(message)), isFalse);
      expect(adapter.available, isFalse);
    },
  );
  test(
    'blackbody colors are bounded and follow warm and cool chromaticity',
    () {
      final warm = xrBlackbodyColor(2500).toList(),
          cool = xrBlackbodyColor(12000).toList();
      expect(warm[0], greaterThan(warm[1]));
      expect(warm[1], greaterThan(warm[2]));
      expect(cool[2], greaterThan(cool[0]));
      for (final t in [1000.0, 2500.0, 6500.0, 12000.0, 40000.0]) {
        expect(
          xrBlackbodyColor(
            t,
          ).toList().every((v) => v.isFinite && v >= 0 && v <= 1),
          isTrue,
        );
      }
      expect(() => xrBlackbodyColor(double.nan), throwsArgumentError);
      expect(
        () => XrAmbientLighting(neutralIntensityLux: 0),
        throwsArgumentError,
      );
    },
  );
}
