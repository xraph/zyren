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
        expect(phone.clouds().preset, CloudQualityPreset.low);
        expect(phone.clouds().maxResolution, 512);
        expect(
          phone.clouds(CloudQualityPreset.medium).preset,
          CloudQualityPreset.medium,
        );
        expect(phone.maxPixels, 1572864);
        expect(phone.tileBytes, 128 * 1024 * 1024);
        expect(phone.selectedTiles, 512);
        expect(phone.decodedTileBytes, 512 * 1024 * 1024);
        expect(tablet.device, CloudDeviceType.tablet);
        expect(tablet.clouds().preset, CloudQualityPreset.high);
        expect(tablet.tileBytes, 192 * 1024 * 1024);
        expect(tablet.resourceBudgetBytes, 512 * 1024 * 1024);
        expect(tablet.selectedTiles, 768);
        expect(tablet.decodedTileBytes, 768 * 1024 * 1024);
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
      expect(desktop.selectedTiles, 1024);
      expect(desktop.decodedTileBytes, 1024 * 1024 * 1024);
      expect(desktop.clouds(CloudQualityPreset.ultra).maxResolution, 4096);
    },
  );
}
