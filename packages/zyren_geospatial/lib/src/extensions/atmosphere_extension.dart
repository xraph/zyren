import 'package:zyren/zyren.dart';
import '../geodesy.dart';
import '../atmosphere/plugin.dart';
import '../atmosphere/parameters.dart';
import '../atmosphere/precomputed_source.dart';
import '../atmosphere/appearance.dart';
import '../atmosphere/star_catalog.dart';
import '../layers/layer.dart';
import 'context.dart';
import 'extension.dart';

final class AtmosphereExtension extends GeospatialExtension {
  @override
  final String localId;
  late final AtmospherePlugin atmosphere;
  GeospatialContext? _geo;
  AtmosphereExtension({
    required String id,
    required DateTime date,
    PrecomputedAtmosphereSource? source,
    AtmosphereParameters? parameters,
    AtmosphereAppearance? appearance,
    Ellipsoid ellipsoid = Ellipsoid.wgs84,
    Mat4? worldToEcef,
    StarCatalog? stars,
    MoonMap? moonMap,
    bool correctAltitude = true,
    int maxStarResolution = 1024,
  }) : localId = id {
    atmosphere = _AtmosphereLayerAdapter(
      instanceId: '${this.id}.atmosphere',
      additionalDependencies: {this.id},
      date: date,
      source: source,
      parameters: parameters,
      appearance: appearance,
      ellipsoid: ellipsoid,
      worldToEcef: worldToEcef,
      stars: stars,
      moonMap: moonMap,
      correctAltitude: correctAltitude,
      maxStarResolution: maxStarResolution,
      onAttached: () {
        final geo = _geo!;
        geo.layers.transact(
          geo.layers.revision,
          (edit) => edit.setStatus(
            localId,
            GeoLayerStatus(
              lifecycle: GeoLayerLifecycle.attached,
              data: GeoLayerDataState.ready,
            ),
          ),
        );
      },
    );
  }
  @override
  List<ScenePlugin> get adapters => [atmosphere];
  @override
  Set<String> get exclusiveCapabilities => const {'atmosphere'};
  @override
  Set<String> get incompatiblePluginIds => const {'atmosphere'};
  @override
  void attachGeospatial(GeospatialContext context) {
    final world = context.reference.ellipsoid;
    if (world.x != atmosphere.ellipsoid.x ||
        world.y != atmosphere.ellipsoid.y ||
        world.z != atmosphere.ellipsoid.z) {
      throw ArgumentError(
        'Atmosphere and geospatial host must use the same ellipsoid.',
      );
    }
    _geo = context;
    context.registerLayer(
      GeoLayer(
        id: localId,
        owner: id,
        kind: 'atmosphere',
        queryable: false,
        status: GeoLayerStatus(
          lifecycle: GeoLayerLifecycle.attaching,
          data: GeoLayerDataState.loading,
        ),
      ),
    );
  }

  @override
  void beforeGeospatialRender(GeospatialContext context, FrameInfo frame) {
    atmosphere.controller.enabled =
        context.layers.findLayer(localId)?.owner == id &&
        context.layers.effectiveVisible(localId);
  }

  @override
  void detachGeospatial(GeospatialContext context) {
    _geo = null;
  }
}

final class _AtmosphereLayerAdapter extends AtmospherePlugin {
  final void Function() onAttached;
  _AtmosphereLayerAdapter({
    required super.instanceId,
    required super.additionalDependencies,
    required super.date,
    super.source,
    super.parameters,
    super.appearance,
    super.ellipsoid,
    super.worldToEcef,
    super.stars,
    super.moonMap,
    super.correctAltitude,
    super.maxStarResolution,
    required this.onAttached,
  });
  @override
  Future<void> attach(PluginContext context) async {
    await super.attach(context);
    if (!context.scope.isClosed) onAttached();
  }
}
