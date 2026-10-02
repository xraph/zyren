// Defaults from the pinned three-geospatial cloud quality presets.
enum CloudQualityPreset { low, medium, high, ultra }

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
  const CloudQuality._({
    required this.resolutionScale,
    required this.lightShafts,
    required this.shapeDetail,
    required this.turbulence,
    required this.haze,
    required this.clouds,
    required this.shadow,
  });
  factory CloudQuality.forPreset(CloudQualityPreset preset) =>
      _presets[preset.index];
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
