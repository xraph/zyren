import 'package:flutter/foundation.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

enum CloudQualitySelection {
  auto('Auto'),
  low('Low'),
  medium('Medium'),
  high('High'),
  ultra('Ultra');

  final String label;
  const CloudQualitySelection(this.label);
  CloudQualityPreset? get preset =>
      this == auto ? null : CloudQualityPreset.values[index - 1];
}

/// Initial limits for the scene, independent of orientation and cloud overrides.
final class GeospatialDeviceProfile {
  final CloudDeviceType device;
  const GeospatialDeviceProfile(this.device);
  factory GeospatialDeviceProfile.forViewport(
    TargetPlatform platform,
    double shortestSide,
  ) => GeospatialDeviceProfile(switch (platform) {
    TargetPlatform.android || TargetPlatform.iOS =>
      shortestSide >= 600 ? CloudDeviceType.tablet : CloudDeviceType.phone,
    _ => CloudDeviceType.desktop,
  });
  int get maxDimension => device == CloudDeviceType.phone ? 1600 : 1920;
  int get maxPixels => device == CloudDeviceType.phone ? 1572864 : 2097152;
  int get tileBytes =>
      (device == CloudDeviceType.phone ? 48 : 64) * 1024 * 1024;
  CloudQualitySettings clouds([CloudQualityPreset? preset]) =>
      CloudQualitySettings.forDevice(device, preset: preset);
}
