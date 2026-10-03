import 'dart:async';
import 'package:zyren/zyren.dart';
import '../geospatial_plugin.dart';
import 'context.dart';
import 'composition.dart';

/// Extend the geospatial hooks and leave core lifecycle dispatch to this base.
/// Required dependencies use full scene plugin IDs, including the host ID.
abstract class GeospatialExtension extends ScenePlugin {
  String get localId;
  int get contractVersion => 1;
  @override
  String get id => 'geospatial.ext.$localId';
  @override
  Set<String> get dependencies => const {GeospatialPlugin.pluginId};

  /// Ordinary scene plugins owned by this extension, with IDs under '$id.'.
  /// Return stable instances. Every adapter receives its own core context.
  List<ScenePlugin> get adapters => const [];

  /// Legacy singleton plugins that cannot coexist with this extension.
  Set<String> get incompatiblePluginIds => const {};

  /// Singleton providers that cannot be installed by two extensions.
  Set<String> get exclusiveCapabilities => const {};

  GeospatialContext? _context;
  FutureOr<void> attachGeospatial(GeospatialContext context);
  FutureOr<void> beforeGeospatialRender(
    GeospatialContext context,
    FrameInfo frame,
  ) {}
  FutureOr<void> detachGeospatial(GeospatialContext context) {}

  @override
  void validateComposition(List<ScenePlugin> plugins) =>
      validateGeospatialExtension(this, plugins);

  @override
  Future<void> attach(PluginContext context) async {
    final host = context.service(geospatialRuntime);
    final scoped = GeospatialContext(sceneContext: context, host: host);
    _context = scoped;
    context.scope.keep(host.registry.beginAttach(id, contractVersion));
    try {
      await attachGeospatial(scoped);
      // Cancellation closes the scope while asynchronous initialization drains.
      if (!context.scope.isClosed) host.registry.markAttached(id);
    } catch (error) {
      if (!context.scope.isClosed) host.registry.markFailed(id, error);
      rethrow;
    }
  }

  @override
  FutureOr<void> beforeRender(PluginContext context, FrameInfo frame) =>
      beforeGeospatialRender(_context!, frame);

  @override
  Future<void> detach(PluginContext context) async {
    final scoped = _context;
    try {
      if (scoped != null) await detachGeospatial(scoped);
    } finally {
      _context = null;
    }
  }
}
