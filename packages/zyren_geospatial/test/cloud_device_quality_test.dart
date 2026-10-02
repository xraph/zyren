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
    expect(settings.maxResolution, 320);
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
      expect(phone.maxResolution, 512);
      expect(tablet.preset, CloudQualityPreset.high);
      expect(desktop.preset, CloudQualityPreset.high);
      expect(desktop.maxResolution, 640);
      for (final device in CloudDeviceType.values) {
        var previous = 0;
        for (final preset in CloudQualityPreset.values) {
          final settings = CloudQualitySettings.forDevice(
            device,
            preset: preset,
          );
          expect(settings.preset, preset);
          expect(settings.maxResolution, greaterThanOrEqualTo(previous));
          expect(settings.maxResolution, lessThanOrEqualTo(768));
          expect(settings.shadowMapSize, lessThanOrEqualTo(256));
          previous = settings.maxResolution;
        }
      }
      expect(
        CloudQualitySettings.forDevice(
          CloudDeviceType.phone,
          preset: CloudQualityPreset.ultra,
        ).maxResolution,
        640,
      );
      expect(
        CloudQualitySettings.forDevice(
          CloudDeviceType.desktop,
          preset: CloudQualityPreset.ultra,
        ).maxResolution,
        768,
      );
    },
  );
  test(
    'invalid cloud target limits fail before allocating native resources',
    () {
      expect(() => CloudQualitySettings(maxResolution: 0), throwsRangeError);
      expect(() => CloudQualitySettings(maxResolution: 1025), throwsRangeError);
      expect(() => CloudQualitySettings(shadowMapSize: 0), throwsRangeError);
      expect(() => CloudQualitySettings(shadowMapSize: 1025), throwsRangeError);
    },
  );
}
