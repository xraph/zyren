import 'package:zyren/zyren.dart';
import 'ellipsoid_geometry.dart';
import 'geodesy.dart';
import 'extensions/extension.dart';
import 'extensions/registry.dart';
import 'extensions/composition.dart';

const geospatialReference = ServiceKey<GeospatialReference>(
  'geospatial.reference',
);

const geospatialRuntime = ServiceKey<GeospatialPlugin>('geospatial.runtime');

/// One world model shared by geospatial plugins in a scene engine.
class GeospatialReference {
  final Ellipsoid ellipsoid;
  const GeospatialReference({this.ellipsoid = Ellipsoid.wgs84});
  Vec3 toEcef(Geodetic coordinate) => ellipsoid.toEcef(coordinate);
  Geodetic fromEcef(Vec3 position) => ellipsoid.fromEcef(position);
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
  final GeoExtensionRegistry registry = GeoExtensionRegistry();
  final List<GeospatialExtension> extensions;
  late final List<ScenePlugin> scenePlugins = List.unmodifiable([
    this,
    for (final extension in extensions) ...[extension, ...extension.adapters],
  ]);
  GeospatialPlugin({
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
    List<GeospatialExtension> extensions = const [],
  }) : reference = GeospatialReference(ellipsoid: ellipsoid),
       extensions = List.unmodifiable(extensions);
  @override
  String get id => pluginId;
  @override
  void validateComposition(List<ScenePlugin> plugins) =>
      validateGeospatialHost(this, plugins);
  @override
  void attach(PluginContext context) {
    context.provide(geospatialReference, reference);
    context.provide(geospatialRuntime, this);
  }
}
