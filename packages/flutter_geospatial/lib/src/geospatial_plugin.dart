import 'package:gpu3d/gpu3d.dart';
import 'ellipsoid_geometry.dart';
import 'geodesy.dart';

const geospatialReference = ServiceKey<GeospatialReference>(
  'geospatial.reference',
);

/// One world model shared by geospatial plugins in a scene engine.
class GeospatialReference {
  final Ellipsoid ellipsoid;
  const GeospatialReference({this.ellipsoid = Ellipsoid.wgs84});
  Vector3 toEcef(Geodetic coordinate) => ellipsoid.toEcef(coordinate);
  Geodetic fromEcef(Vector3 position) => ellipsoid.fromEcef(position);
  EastNorthUpFrame localFrame(Geodetic origin) =>
      EastNorthUpFrame(origin, ellipsoid: ellipsoid);
  EllipsoidGeometry globeGeometry({
    int longitudeSegments = 96,
    int latitudeSegments = 48,
  }) => EllipsoidGeometry(
    ellipsoid: ellipsoid,
    longitudeSegments: longitudeSegments,
    latitudeSegments: latitudeSegments,
  );
}

/// Optional domain plugin. The core has no dependency on this package.
class GeospatialPlugin extends ScenePlugin {
  static const pluginId = 'geospatial';
  final GeospatialReference reference;
  GeospatialPlugin({Ellipsoid ellipsoid = Ellipsoid.wgs84})
    : reference = GeospatialReference(ellipsoid: ellipsoid);
  @override
  String get id => pluginId;
  @override
  void attach(PluginContext context) =>
      context.provide(geospatialReference, reference);
}
