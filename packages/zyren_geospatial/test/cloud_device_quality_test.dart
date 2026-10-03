import 'package:test/test.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test('shadow quality and allocation limits are independent of clouds', () {
    final settings = CloudQualitySettings.forDevice(
      CloudDeviceType.desktop,
      preset: CloudQualityPreset.low,
      shadowPreset: CloudQualityPreset.ultra,
      shadowsEnabled: false,
    );
    expect(settings.preset, CloudQualityPreset.low);
    expect(settings.maxResolution, 512);
    expect(settings.shadowMapSize, 256);
    expect(settings.shadowsEnabled, false);
    final quality = CloudQuality.forPreset(
      CloudQualityPreset.high,
      shadowPreset: CloudQualityPreset.low,
      shadowsEnabled: false,
    );
    expect(
      quality.clouds,
      same(CloudQuality.forPreset(CloudQualityPreset.high).clouds),
    );
    expect(quality.shadow.cascadeCount, 2);
    expect(quality.shadow.maxIterationCount, 25);
    expect(quality.lightShafts, false);
  });
  test(
    'device defaults retain the source sampling presets within size limits',
    () {
      final phone = CloudQualitySettings.forDevice(CloudDeviceType.phone);
      final tablet = CloudQualitySettings.forDevice(CloudDeviceType.tablet);
      final desktop = CloudQualitySettings.forDevice(CloudDeviceType.desktop);
      expect(phone.preset, CloudQualityPreset.medium);
      expect(phone.maxResolution, 768);
      expect(tablet.preset, CloudQualityPreset.high);
      expect(desktop.preset, CloudQualityPreset.high);
      expect(desktop.maxResolution, 1920);
      for (final device in CloudDeviceType.values) {
        var previous = 0, previousPixels = 0;
        for (final preset in CloudQualityPreset.values) {
          final settings = CloudQualitySettings.forDevice(
            device,
            preset: preset,
          );
          expect(settings.preset, preset);
          expect(settings.maxResolution, greaterThanOrEqualTo(previous));
          expect(settings.maxResolution, lessThanOrEqualTo(4096));
          expect(settings.maxPixels, greaterThanOrEqualTo(previousPixels));
          expect(settings.shadowMapSize, lessThanOrEqualTo(256));
          for (final view in [(4096, 4096), (1920, 1200), (1, 8000)]) {
            final (w, h) = settings.targetSize(view.$1, view.$2);
            expect(w * h, lessThanOrEqualTo(settings.maxPixels));
            expect(w, lessThanOrEqualTo(settings.maxResolution));
            expect(h, lessThanOrEqualTo(settings.maxResolution));
          }
          previous = settings.maxResolution;
          previousPixels = settings.maxPixels;
        }
      }
      expect(
        CloudQualitySettings.forDevice(
          CloudDeviceType.phone,
          preset: CloudQualityPreset.ultra,
        ).maxResolution,
        1920,
      );
      expect(
        CloudQualitySettings.forDevice(
          CloudDeviceType.desktop,
          preset: CloudQualityPreset.ultra,
        ).maxResolution,
        4096,
      );
    },
  );
  test(
    'High fills a desktop HD view and Ultra accepts a larger native target',
    () {
      final high = CloudQualitySettings.forDevice(CloudDeviceType.desktop);
      final ultra = CloudQualitySettings.forDevice(
        CloudDeviceType.desktop,
        preset: CloudQualityPreset.ultra,
      );
      expect(high.targetSize(1920, 1080), (1920, 1080));
      expect(ultra.targetSize(3424, 1818), (3424, 1818));
      // Balanced phone settings still use a smaller target at the same size.
      final phone = CloudQualitySettings.forDevice(CloudDeviceType.phone);
      expect(phone.targetSize(1920, 1080), (768, 432));
    },
  );
  test(
    'invalid cloud target limits fail before allocating native resources',
    () {
      expect(() => CloudQualitySettings(maxResolution: 0), throwsRangeError);
      expect(() => CloudQualitySettings(maxResolution: 4097), throwsRangeError);
      expect(() => CloudQualitySettings(maxPixels: 0), throwsRangeError);
      expect(() => CloudQualitySettings(shadowMapSize: 0), throwsRangeError);
      expect(() => CloudQualitySettings(shadowMapSize: 1025), throwsRangeError);
    },
  );
}
