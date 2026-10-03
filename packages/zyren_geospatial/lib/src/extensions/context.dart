import 'package:zyren/zyren.dart';
import '../geospatial_plugin.dart';
import 'registry.dart';
import 'camera_controller.dart';
import 'visual_registry.dart';
import '../layers/controller.dart';
import '../layers/layer.dart';
import '../world/reference.dart';
import '../world/time.dart';

/// Domain services wrapped around this extension's own core attachment.
final class GeospatialContext {
  final PluginContext sceneContext;
  final GeospatialPlugin host;
  const GeospatialContext({required this.sceneContext, required this.host});
  GeoVisualRegistry get visuals => host.visuals;
  GeoCameraController get cameras => host.cameras;
  GeoWorldFrame get worldFrame => host.worldFrame;
  GeoSimulationClock get clock => host.clock;
  GeoHeightProvider get heightProvider => host.heightProvider;
  GeoLayerController get layers => host.layers;
  Registration registerLayer(GeoLayer layer) {
    _requireActive();
    return sceneContext.scope.keep(layers.register(layer, adoptRestored: true));
  }

  GeospatialReference get reference => host.reference;
  GeoExtensionRegistry get registry => host.registry;

  Registration provide<T extends Object>(GeoServiceKey<T> key, T value) {
    _requireActive();
    return sceneContext.scope.keep(registry.provide(key, value));
  }

  T? find<T extends Object>(GeoServiceKey<T> key) {
    _requireActive();
    return registry.find(key);
  }

  void _requireActive() {
    if (sceneContext.scope.isClosed) {
      throw StateError('Geospatial attachment has closed.');
    }
  }
}
