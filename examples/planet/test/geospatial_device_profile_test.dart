import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:planet/geospatial_device_profile.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  test(
    'phone, tablet and desktop defaults depend on device size and platform',
    () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        final phone = GeospatialDeviceProfile.forViewport(platform, 430);
        final tablet = GeospatialDeviceProfile.forViewport(platform, 820);
        expect(phone.device, CloudDeviceType.phone);
        expect(phone.clouds().preset, CloudQualityPreset.medium);
        expect(phone.maxPixels, 1572864);
        expect(phone.tileBytes, 128 * 1024 * 1024);
        expect(tablet.device, CloudDeviceType.tablet);
        expect(tablet.clouds().preset, CloudQualityPreset.high);
        expect(tablet.tileBytes, 192 * 1024 * 1024);
        expect(tablet.resourceBudgetBytes, 512 * 1024 * 1024);
      }
      final desktop = GeospatialDeviceProfile.forViewport(
        TargetPlatform.macOS,
        390,
      );
      expect(desktop.device, CloudDeviceType.desktop);
      expect(desktop.maxDimension, 1920);
      expect(desktop.maxPixels, 2097152);
      expect(desktop.tileBytes, 384 * 1024 * 1024);
      expect(desktop.resourceBudgetBytes, 768 * 1024 * 1024);
      expect(desktop.clouds(CloudQualityPreset.ultra).maxResolution, 1536);
    },
  );
}
