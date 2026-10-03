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
  int get tileBytes => switch (device) {
    CloudDeviceType.phone => 128 * 1024 * 1024,
    CloudDeviceType.tablet => 192 * 1024 * 1024,
    CloudDeviceType.desktop => 384 * 1024 * 1024,
  };
  int get tileRequests => device == CloudDeviceType.phone ? 6 : 8;
  int get sceneUploadBudgetBytes =>
      (device == CloudDeviceType.phone ? 2 : 4) * 1024 * 1024;
  int get selectedTiles => switch (device) {
    CloudDeviceType.phone => 512,
    CloudDeviceType.tablet => 768,
    CloudDeviceType.desktop => 1024,
  };
  int get decodedTileBytes => switch (device) {
    CloudDeviceType.phone => 512 * 1024 * 1024,
    CloudDeviceType.tablet => 768 * 1024 * 1024,
    CloudDeviceType.desktop => 1024 * 1024 * 1024,
  };
  int get resourceBudgetBytes => switch (device) {
    CloudDeviceType.phone => 384 * 1024 * 1024,
    CloudDeviceType.tablet => 512 * 1024 * 1024,
    CloudDeviceType.desktop => 768 * 1024 * 1024,
  };
  CloudQualitySettings clouds([
    CloudQualityPreset? preset,
    bool shadowsEnabled = true,
    CloudQualityPreset? shadowPreset,
  ]) => CloudQualitySettings.forDevice(
    device,
    preset:
        preset ??
        (device == CloudDeviceType.phone ? CloudQualityPreset.low : null),
    shadowsEnabled: shadowsEnabled,
    shadowPreset: shadowPreset,
  );
}
