import 'package:zyren/zyren.dart';
import '../layers/layer.dart';
import '../layers/selection.dart';
import '../streaming/tile_source.dart';
import '../terrain/terrain_plugin.dart';
import '../terrain/terrain_tile.dart';
import '../terrain/imagery_terrain_source.dart';
import '../terrain/imagery_source.dart';
import 'context.dart';
import 'extension.dart';

/// One named imagery contribution to a terrain's ordered composition stack.
final class GeoImageryLayer {
  final String id;
  final RasterImagerySource source;
  final double opacity;
  final int levelOffset;
  GeoImageryLayer({
    required this.id,
    required this.source,
    this.opacity = 1,
    this.levelOffset = 0,
  }) {
    ImageryLayer(source, opacity: opacity, levelOffset: levelOffset);
    if (id.trim().isEmpty) throw ArgumentError('An imagery layer needs an ID.');
  }
}

final class TerrainExtension extends GeospatialExtension {
  @override
  final String localId;
  final TerrainSource _baseSource;
  final TileBudget? budget;
  final double maximumScreenError;
  final List<GeoImageryLayer> imagery;
  final int imagerySize;
  late final TerrainPlugin terrain = TerrainPlugin(
    source: _baseSource,
    instanceId: '$id.terrain',
    additionalDependencies: {id},
    budget: budget,
    maximumScreenError: maximumScreenError,
    onChanged: (_) => _publishStatus(),
  );
  GeospatialContext? _geo;
  Object? _lastStatus, _lastImagery;
  int _imageryRevision = 0;
  TerrainExtension({
    required String id,
    required TerrainSource source,
    this.budget,
    this.maximumScreenError = 8,
    List<GeoImageryLayer> imagery = const [],
    this.imagerySize = 256,
  }) : localId = id,
       _baseSource = source,
       imagery = List.unmodifiable(imagery) {
    if (imagery.length > 4 ||
        imagery.map((layer) => layer.id).toSet().length != imagery.length ||
        imagery.any((layer) => layer.id == id)) {
      throw ArgumentError(
        'Imagery layer IDs must be distinct, with at most four layers.',
      );
    }
  }
  String get layerId => localId;
  @override
  List<ScenePlugin> get adapters => [terrain];
  @override
  Set<String> get incompatiblePluginIds => const {'geospatial.terrain'};
  @override
  void attachGeospatial(GeospatialContext context) {
    _geo = context;
    context.registerLayer(
      GeoLayer(
        id: layerId,
        owner: id,
        kind: 'terrain',
        capabilities: {
          GeoLayerCapability.query,
          GeoLayerCapability.reorder,
          GeoLayerCapability.refresh,
        },
        sourceReference: _baseSource.identity,
        sourceRevision: _baseSource.identity,
        status: GeoLayerStatus(
          lifecycle: GeoLayerLifecycle.attaching,
          data: GeoLayerDataState.loading,
        ),
      ),
    );
    for (final image in imagery) {
      context.registerLayer(
        GeoLayer(
          id: image.id,
          owner: id,
          kind: 'raster-imagery',
          opacity: image.opacity,
          queryable: false,
          capabilities: {
            GeoLayerCapability.opacity,
            GeoLayerCapability.reorder,
          },
          sourceReference: image.source.identity,
          sourceRevision: image.source.identity,
        ),
      );
    }
  }

  @override
  void beforeGeospatialRender(GeospatialContext context, FrameInfo frame) {
    final layer = context.layers.findLayer(layerId);
    if (layer == null || layer.owner != id) {
      terrain.visible = false;
      terrain.retainWhenHidden = false;
      return;
    }
    terrain.visible = context.layers.effectiveVisible(layerId);
    terrain.retainWhenHidden =
        layer.policies.retention == GeoHiddenRetention.retain;
    if (imagery.isNotEmpty) {
      final byId = {for (final image in imagery) image.id: image};
      final ordered = context.layers.snapshot
          .where((layer) => layer.owner == id && byId.containsKey(layer.id))
          .toList();
      final signature = ordered
          .map(
            (layer) => (
              layer.id,
              context.layers.effectiveVisible(layer.id)
                  ? context.layers.effectiveOpacity(layer.id)
                  : 0.0,
            ),
          )
          .toList();
      final key = signature.map((entry) => '${entry.$1}:${entry.$2}').join('|');
      if (_lastImagery != key) {
        setImageryStack(
          [
            for (final entry in signature)
              ImageryLayer(
                byId[entry.$1]!.source,
                opacity: entry.$2,
                levelOffset: byId[entry.$1]!.levelOffset,
              ),
          ],
          revision: _imageryRevision + 1,
          outputSize: imagerySize,
        );
        _lastImagery = key;
      }
    }
    _publishStatus();
  }

  void setImageryStack(
    List<ImageryLayer> layers, {
    required int revision,
    int outputSize = 256,
    int maxTilesPerLayer = 4,
  }) {
    terrain.setImageryStack(
      layers,
      revision: revision,
      outputSize: outputSize,
      maxTilesPerLayer: maxTilesPerLayer,
      terrain: _baseSource,
    );
    _imageryRevision = revision;
    _geo?.sceneContext.invalidate();
  }

  void retryFailed() => terrain.retryFailed();
  List<GeoFeatureHit> pick(CameraRay ray) {
    final geo = _geo;
    if (geo == null ||
        geo.layers.findLayer(layerId)?.owner != id ||
        !geo.layers.effectiveQueryable(layerId)) {
      return const [];
    }
    return [
      for (final result in terrain.pick(ray))
        GeoFeatureHit(
          layerId: layerId,
          featureId:
              '${result.coordinate.z}/${result.coordinate.x}/${result.coordinate.y}',
          position: geo.reference.fromEcef(result.hit.point),
          sourceRevision: geo.layers.layer(layerId).sourceRevision!,
          metadata: result.hit,
        ),
    ];
  }

  void _publishStatus() {
    final geo = _geo;
    final stats = terrain.stats;
    if (geo == null ||
        geo.sceneContext.scope.isClosed ||
        stats == null ||
        geo.layers.findLayer(layerId)?.owner != id) {
      return;
    }
    final data = terrain.retainingPreviousSource
        ? GeoLayerDataState.stale
        : terrain.failures.isNotEmpty
        ? (stats.visibleTiles > 0
              ? GeoLayerDataState.partial
              : GeoLayerDataState.failed)
        : stats.activeRequests > 0
        ? (stats.visibleTiles > 0
              ? GeoLayerDataState.partial
              : GeoLayerDataState.loading)
        : stats.visibleTiles > 0
        ? GeoLayerDataState.ready
        : GeoLayerDataState.unavailable;
    final key = (
      data,
      stats.visibleTiles,
      terrain.attributions.join('|'),
      terrain.source.identity,
      _imageryRevision,
    );
    if (key == _lastStatus) return;
    _lastStatus = key;
    final status = GeoLayerStatus(
      lifecycle: GeoLayerLifecycle.attached,
      data: data,
      attribution: terrain.attributions,
      failure: terrain.failures.isEmpty
          ? null
          : const GeoLayerFailure(
              code: 'terrain_source',
              message: 'Terrain content could not be loaded.',
              retryable: true,
            ),
    );
    geo.layers.transact(geo.layers.revision, (edit) {
      edit.setStatus(layerId, status);
      edit.setStyleRevision(layerId, '$_imageryRevision');
      for (final image in imagery) {
        if (geo.layers.findLayer(image.id)?.owner == id) {
          edit.setStatus(
            image.id,
            GeoLayerStatus(
              lifecycle: status.lifecycle,
              data: status.data,
              failure: status.failure,
              attribution:
                  terrain.attributions.contains(image.source.attribution)
                  ? [image.source.attribution]
                  : const [],
            ),
          );
        }
      }
    });
  }

  @override
  void detachGeospatial(GeospatialContext context) {
    _geo = null;
    _lastStatus = null;
    _lastImagery = null;
  }
}
