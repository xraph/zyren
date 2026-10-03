import 'dart:math' as math;

// Defaults from the pinned three-geospatial cloud quality presets.
enum CloudQualityPreset { low, medium, high, ultra }

enum CloudDeviceType { phone, tablet, desktop }

/// Source sampling quality with explicit native texture limits.
/// A null shadow size uses the selected source preset's map size.
final class CloudQualitySettings {
  final CloudQualityPreset preset;
  final int maxResolution;
  final int maxPixels;
  final int? shadowMapSize;
  final bool shadowsEnabled;
  final CloudQualityPreset? shadowPreset;
  CloudQualitySettings({
    this.preset = CloudQualityPreset.medium,
    this.maxResolution = 384,
    this.maxPixels = 1048576,
    this.shadowMapSize,
    this.shadowsEnabled = true,
    this.shadowPreset,
  }) {
    RangeError.checkValueInInterval(maxResolution, 1, 4096, 'maxResolution');
    RangeError.checkValueInInterval(maxPixels, 1, 16777216, 'maxPixels');
    if (shadowMapSize case final size?) {
      RangeError.checkValueInInterval(size, 1, 1024, 'shadowMapSize');
    }
  }

  (int, int) targetSize(int width, int height) {
    final w = math.max(1, width), h = math.max(1, height);
    final scale = math.min(
      1.0,
      math.min(maxResolution / math.max(w, h), math.sqrt(maxPixels / (w * h))),
    );
    var targetWidth = math.max(1, (w * scale).round());
    var targetHeight = math.max(1, (h * scale).round());
    if (targetWidth * targetHeight > maxPixels) {
      if (targetWidth >= targetHeight) {
        targetWidth = math.max(1, maxPixels ~/ targetHeight);
      } else {
        targetHeight = math.max(1, maxPixels ~/ targetWidth);
      }
    }
    return (targetWidth, targetHeight);
  }

  /// Balanced starting points. Choose your device class explicitly; native
  /// applications can override these limits for their own GPU and scene budget.
  factory CloudQualitySettings.forDevice(
    CloudDeviceType device, {
    CloudQualityPreset? preset,
    bool shadowsEnabled = true,
    CloudQualityPreset? shadowPreset,
  }) {
    final selected =
        preset ??
        (device == CloudDeviceType.phone
            ? CloudQualityPreset.medium
            : CloudQualityPreset.high);
    return CloudQualitySettings(
      preset: selected,
      shadowsEnabled: shadowsEnabled,
      shadowPreset: shadowPreset,
      maxPixels: switch (device) {
        CloudDeviceType.phone => 589824,
        CloudDeviceType.tablet => 921600,
        CloudDeviceType.desktop => 1048576,
      },
      maxResolution: switch (selected) {
        CloudQualityPreset.low => 512,
        CloudQualityPreset.medium =>
          device == CloudDeviceType.phone ? 768 : 1024,
        CloudQualityPreset.high => switch (device) {
          CloudDeviceType.phone => 960,
          CloudDeviceType.tablet => 1152,
          CloudDeviceType.desktop => 1280,
        },
        CloudQualityPreset.ultra => switch (device) {
          CloudDeviceType.phone => 1024,
          CloudDeviceType.tablet => 1280,
          CloudDeviceType.desktop => 1536,
        },
      },
      shadowMapSize: (shadowPreset ?? selected) == CloudQualityPreset.ultra
          ? (device == CloudDeviceType.desktop ? 256 : 192)
          : 128,
    );
  }
}

final class CloudMarchQuality {
  final int multiScatteringOctaves;
  final bool accurateSunSkyLight;
  final bool accuratePhaseFunction;
  final int maxIterationCount;
  final double minStepSize;
  final double maxStepSize;
  final double maxRayDistance;
  final double perspectiveStepScale;
  final double minDensity;
  final double minExtinction;
  final double minTransmittance;
  final int maxIterationCountToGround;
  final int maxIterationCountToSun;
  final double minSecondaryStepSize;
  final double secondaryStepScale;
  final int maxShadowLengthIterationCount;
  final double minShadowLengthStepSize;
  final double maxShadowLengthRayDistance;
  const CloudMarchQuality._({
    required this.multiScatteringOctaves,
    required this.accurateSunSkyLight,
    required this.accuratePhaseFunction,
    required this.maxIterationCount,
    required this.minStepSize,
    required this.maxStepSize,
    required this.maxRayDistance,
    required this.perspectiveStepScale,
    required this.minDensity,
    required this.minExtinction,
    required this.minTransmittance,
    required this.maxIterationCountToGround,
    required this.maxIterationCountToSun,
    required this.minSecondaryStepSize,
    required this.secondaryStepScale,
    required this.maxShadowLengthIterationCount,
    required this.minShadowLengthStepSize,
    required this.maxShadowLengthRayDistance,
  });
  Map<String, Object> toJson() => {
    'multiScatteringOctaves': multiScatteringOctaves,
    'accurateSunSkyLight': accurateSunSkyLight,
    'accuratePhaseFunction': accuratePhaseFunction,
    'maxIterationCount': maxIterationCount,
    'minStepSize': minStepSize,
    'maxStepSize': maxStepSize,
    'maxRayDistance': maxRayDistance,
    'perspectiveStepScale': perspectiveStepScale,
    'minDensity': minDensity,
    'minExtinction': minExtinction,
    'minTransmittance': minTransmittance,
    'maxIterationCountToGround': maxIterationCountToGround,
    'maxIterationCountToSun': maxIterationCountToSun,
    'minSecondaryStepSize': minSecondaryStepSize,
    'secondaryStepScale': secondaryStepScale,
    'maxShadowLengthIterationCount': maxShadowLengthIterationCount,
    'minShadowLengthStepSize': minShadowLengthStepSize,
    'maxShadowLengthRayDistance': maxShadowLengthRayDistance,
  };
}

final class CloudShadowQuality {
  final int cascadeCount;
  final (int, int) mapSize;
  final int maxIterationCount;
  final double minStepSize;
  final double maxStepSize;
  final double minDensity;
  final double minExtinction;
  final double minTransmittance;
  const CloudShadowQuality._({
    required this.cascadeCount,
    required this.mapSize,
    required this.maxIterationCount,
    required this.minStepSize,
    required this.maxStepSize,
    required this.minDensity,
    required this.minExtinction,
    required this.minTransmittance,
  });
  Map<String, Object> toJson() => {
    'cascadeCount': cascadeCount,
    'mapSize': [mapSize.$1, mapSize.$2],
    'maxIterationCount': maxIterationCount,
    'minStepSize': minStepSize,
    'maxStepSize': maxStepSize,
    'minDensity': minDensity,
    'minExtinction': minExtinction,
    'minTransmittance': minTransmittance,
  };
}

/// Source raymarch and shadow settings. Select a preset before allocating passes.
final class CloudQuality {
  final double resolutionScale;
  final bool lightShafts, shapeDetail, turbulence, haze;
  final CloudMarchQuality clouds;
  final CloudShadowQuality shadow;
  final bool shadowsEnabled;
  const CloudQuality._({
    required this.resolutionScale,
    required this.lightShafts,
    required this.shapeDetail,
    required this.turbulence,
    required this.haze,
    required this.clouds,
    required this.shadow,
    this.shadowsEnabled = true,
  });
  factory CloudQuality.forPreset(
    CloudQualityPreset preset, {
    bool shadowsEnabled = true,
    CloudQualityPreset? shadowPreset,
  }) {
    final clouds = _presets[preset.index];
    if (shadowsEnabled && shadowPreset == null) return clouds;
    return CloudQuality._(
      resolutionScale: clouds.resolutionScale,
      lightShafts: shadowsEnabled && clouds.lightShafts,
      shapeDetail: clouds.shapeDetail,
      turbulence: clouds.turbulence,
      haze: clouds.haze,
      clouds: clouds.clouds,
      shadow: _presets[(shadowPreset ?? preset).index].shadow,
      shadowsEnabled: shadowsEnabled,
    );
  }
  Map<String, Object> toJson() => {
    'resolutionScale': resolutionScale,
    'lightShafts': lightShafts,
    'shapeDetail': shapeDetail,
    'turbulence': turbulence,
    'haze': haze,
    'clouds': clouds.toJson(),
    'shadow': shadow.toJson(),
  };
  static const _presets = <CloudQuality>[
    CloudQuality._(
      resolutionScale: 1,
      lightShafts: false,
      shapeDetail: false,
      turbulence: false,
      haze: true,
      clouds: CloudMarchQuality._(
        multiScatteringOctaves: 8,
        accurateSunSkyLight: false,
        accuratePhaseFunction: false,
        maxIterationCount: 200,
        minStepSize: 100,
        maxStepSize: 1000,
        maxRayDistance: 100000,
        perspectiveStepScale: 1.01,
        minDensity: 0.0001,
        minExtinction: 0.0001,
        minTransmittance: 0.1,
        maxIterationCountToGround: 0,
        maxIterationCountToSun: 1,
        minSecondaryStepSize: 100,
        secondaryStepScale: 2,
        maxShadowLengthIterationCount: 500,
        minShadowLengthStepSize: 50,
        maxShadowLengthRayDistance: 200000,
      ),
      shadow: CloudShadowQuality._(
        cascadeCount: 2,
        mapSize: (256, 256),
        maxIterationCount: 25,
        minStepSize: 100,
        maxStepSize: 1000,
        minDensity: 0.0001,
        minExtinction: 0.0001,
        minTransmittance: 0.01,
      ),
    ),
    CloudQuality._(
      resolutionScale: 1,
      lightShafts: false,
      shapeDetail: true,
      turbulence: false,
      haze: true,
      clouds: CloudMarchQuality._(
        multiScatteringOctaves: 8,
        accurateSunSkyLight: false,
        accuratePhaseFunction: false,
        maxIterationCount: 500,
        minStepSize: 50,
        maxStepSize: 1000,
        maxRayDistance: 200000,
        perspectiveStepScale: 1.01,
        minDensity: 0.0001,
        minExtinction: 0.0001,
        minTransmittance: 0.01,
        maxIterationCountToGround: 1,
        maxIterationCountToSun: 2,
        minSecondaryStepSize: 100,
        secondaryStepScale: 2,
        maxShadowLengthIterationCount: 500,
        minShadowLengthStepSize: 50,
        maxShadowLengthRayDistance: 200000,
      ),
      shadow: CloudShadowQuality._(
        cascadeCount: 3,
        mapSize: (256, 256),
        maxIterationCount: 50,
        minStepSize: 100,
        maxStepSize: 1000,
        minDensity: 0.0001,
        minExtinction: 0.0001,
        minTransmittance: 0.0001,
      ),
    ),
    CloudQuality._(
      resolutionScale: 1,
      lightShafts: true,
      shapeDetail: true,
      turbulence: true,
      haze: true,
      clouds: CloudMarchQuality._(
        multiScatteringOctaves: 8,
        accurateSunSkyLight: true,
        accuratePhaseFunction: false,
        maxIterationCount: 500,
        minStepSize: 50,
        maxStepSize: 1000,
        maxRayDistance: 200000,
        perspectiveStepScale: 1.01,
        minDensity: 1e-05,
        minExtinction: 1e-05,
        minTransmittance: 0.01,
        maxIterationCountToGround: 3,
        maxIterationCountToSun: 2,
        minSecondaryStepSize: 100,
        secondaryStepScale: 2,
        maxShadowLengthIterationCount: 500,
        minShadowLengthStepSize: 50,
        maxShadowLengthRayDistance: 200000,
      ),
      shadow: CloudShadowQuality._(
        cascadeCount: 3,
        mapSize: (512, 512),
        maxIterationCount: 50,
        minStepSize: 100,
        maxStepSize: 1000,
        minDensity: 1e-05,
        minExtinction: 1e-05,
        minTransmittance: 0.0001,
      ),
    ),
    CloudQuality._(
      resolutionScale: 1,
      lightShafts: true,
      shapeDetail: true,
      turbulence: true,
      haze: true,
      clouds: CloudMarchQuality._(
        multiScatteringOctaves: 8,
        accurateSunSkyLight: true,
        accuratePhaseFunction: false,
        maxIterationCount: 500,
        minStepSize: 10,
        maxStepSize: 1000,
        maxRayDistance: 200000,
        perspectiveStepScale: 1.01,
        minDensity: 1e-05,
        minExtinction: 1e-05,
        minTransmittance: 0.01,
        maxIterationCountToGround: 3,
        maxIterationCountToSun: 2,
        minSecondaryStepSize: 100,
        secondaryStepScale: 2,
        maxShadowLengthIterationCount: 500,
        minShadowLengthStepSize: 50,
        maxShadowLengthRayDistance: 200000,
      ),
      shadow: CloudShadowQuality._(
        cascadeCount: 3,
        mapSize: (1024, 1024),
        maxIterationCount: 50,
        minStepSize: 100,
        maxStepSize: 1000,
        minDensity: 1e-05,
        minExtinction: 1e-05,
        minTransmittance: 0.0001,
      ),
    ),
  ];
}
