import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';

OceanSeaState fixtureSea({
  int seed = 42,
  int resolution = 8,
  double? depth,
  double wind = 12,
}) => OceanSeaState(
  seed: seed,
  canonicalResolution: resolution,
  bands: [
    OceanWaveBand(
      patchMetres: 64,
      minWaveNumber: 0,
      maxWaveNumber: .5,
      windSpeed: wind,
      windHeadingRadians: .3,
      amplitude: .02,
      depthMetres: depth,
    ),
  ],
);
