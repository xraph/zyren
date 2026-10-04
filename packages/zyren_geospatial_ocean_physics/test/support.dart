import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial_ocean/zyren_geospatial_ocean.dart';
import 'package:zyren_physics/zyren_physics.dart';

final epoch = DateTime.utc(2026);
OceanSeaState calmSea() => OceanSeaState(
  seed: 12,
  canonicalResolution: 4,
  bands: [
    OceanWaveBand(
      patchMetres: 64,
      minWaveNumber: 0,
      maxWaveNumber: .5,
      windSpeed: 12,
      windHeadingRadians: 0,
      amplitude: 0,
      choppiness: 0,
    ),
  ],
);
GeoWorldFrame worldFrame() => GeoWorldFrame(
  reference: const GeospatialReference(),
  origin: Geodetic(0, 0),
);
BuoyancyHull cubeShape() => BuoyancyHull(
  vertices: const [
    Vec3(-1, -1, -1),
    Vec3(1, -1, -1),
    Vec3(1, 1, -1),
    Vec3(-1, 1, -1),
    Vec3(-1, -1, 1),
    Vec3(1, -1, 1),
    Vec3(1, 1, 1),
    Vec3(-1, 1, 1),
  ],
  indices: const [
    0,
    2,
    1,
    0,
    3,
    2,
    4,
    5,
    6,
    4,
    6,
    7,
    0,
    1,
    5,
    0,
    5,
    4,
    3,
    7,
    6,
    3,
    6,
    2,
    0,
    4,
    7,
    0,
    7,
    3,
    1,
    2,
    6,
    1,
    6,
    5,
  ],
);
BuoyancyProbes vesselShape() => BuoyancyProbes([
  for (final x in [-2.0, 2.0])
    for (final y in [-1.0, 1.0]) BuoyancyProbe(Vec3(x, y, 0), .5),
]);
PhysicsBody cube(
  PhysicsWorld world, {
  double density = 500,
  Vec3 position = Vec3.zero,
}) {
  final body = world.createBody(pose: PhysicsPose(position: position));
  body.addCollider(const BoxShape(Vec3.one), density: density);
  return body;
}

final class FixtureCoverage implements GeoFieldSource<bool> {
  @override
  String get id => 'fixture-ocean';
  @override
  String revision = 'one';
  bool available = true;
  Future<void>? gate;
  @override
  String get units => 'boolean';
  @override
  GeoHeightDatum? get datum => null;
  @override
  Future<GeoSample<bool>> sample(Geodetic coordinate, GeoInstant time) async {
    await gate;
    return GeoSample(
      availability: available
          ? GeoSampleAvailability.available
          : GeoSampleAvailability.unavailable,
      value: available ? true : null,
      frameId: 'body-fixed',
      frameRevision: 0,
      sourceRevision: revision,
      units: units,
      time: time,
      age: Duration.zero,
    );
  }
}

final class FixtureCurrent implements GeoFieldSource<Vec3> {
  @override
  String get id => 'fixture-current';
  @override
  String revision = 'one';
  Vec3 velocity = Vec3.zero;
  double error = 0;
  bool available = true;
  @override
  String get units => 'm/s';
  @override
  GeoHeightDatum? get datum => null;
  @override
  Future<GeoSample<Vec3>> sample(Geodetic coordinate, GeoInstant time) async =>
      GeoSample(
        availability: available
            ? GeoSampleAvailability.available
            : GeoSampleAvailability.unavailable,
        value: available ? velocity : null,
        frameId: 'body-fixed',
        frameRevision: 0,
        sourceRevision: revision,
        units: units,
        time: time,
        age: Duration.zero,
        error: error,
      );
}
