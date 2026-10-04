import 'dart:async';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'queries/sampler.dart';
import 'waves/sea_state.dart';

const oceanSeaState = GeoServiceKey<OceanSeaState>('ocean.sea-state', 1);
const oceanSampler = GeoServiceKey<OceanSampler>('ocean.sampler', 1);
const oceanPresentation = GeoServiceKey<OceanPresentation>(
  'ocean.presentation',
  1,
);

final class OceanLayerVisibility {
  final bool surface, foam, underwater;
  const OceanLayerVisibility({
    required this.surface,
    required this.foam,
    required this.underwater,
  });
}

/// Visual work under the application's frame owner. Implementations must not
/// advance the simulation clock. The extension owns the returned presentation.
abstract interface class OceanPresentation {
  bool get hasUnderwater;
  bool get isReady;
  Future<void> prepare(
    GeoInstant instant,
    FrameInfo frame,
    OceanLayerVisibility visibility,
  );
  Future<void> close();
}

/// Composes water through the geospatial host without claiming the physics clock.
/// Factories transfer ownership of their results to this attachment. Data access,
/// coverage, query policy and native presentation remain explicit application inputs.
final class OceanExtension extends GeospatialExtension {
  @override
  final String localId;
  final OceanSeaState state;
  final Future<OceanSampler> Function(GeospatialContext) createSampler;
  final FutureOr<OceanPresentation> Function(GeospatialContext, OceanSampler)
  createPresentation;
  final Set<String> _dependencies;
  OceanSampler? _sampler;
  OceanPresentation? _presentation;
  Completer<void>? _attached;
  Future<void>? _closing;
  bool _closed = true;
  GeoLayerDataState? _published;
  OceanExtension({
    String id = 'ocean',
    required this.state,
    required this.createSampler,
    required this.createPresentation,
    Set<String> dependencies = const {},
  }) : localId = id,
       _dependencies = Set.unmodifiable(dependencies);
  String get surfaceLayerId => '$localId.surface';
  String get foamLayerId => '$localId.foam';
  String get underwaterLayerId => '$localId.underwater';
  OceanPresentation? get presentation => _presentation;
  @override
  Set<String> get dependencies => {GeospatialPlugin.pluginId, ..._dependencies};
  @override
  Set<String> get exclusiveCapabilities => const {'ocean'};

  @override
  Future<void> attachGeospatial(GeospatialContext context) async {
    _closed = false;
    _closing = null;
    _published = null;
    final attached = _attached = Completer<void>();
    context.sceneContext.scope.onClose(_close);
    try {
      final sampler = _sampler = await createSampler(context);
      if (_closed || context.sceneContext.scope.isClosed) {
        throw StateError('Ocean attachment closed.');
      }
      if (sampler.state.revision != state.revision ||
          !identical(sampler.frame, context.worldFrame)) {
        throw ArgumentError(
          'Ocean sampler must share the host world frame and canonical sea state.',
        );
      }
      final presentation = _presentation = await createPresentation(
        context,
        sampler,
      );
      if (_closed || context.sceneContext.scope.isClosed) {
        throw StateError('Ocean attachment closed.');
      }
      context.registerLayer(GeoLayer(id: localId, owner: id, kind: 'group'));
      for (final (layerId, kind, queryable) in [
        (surfaceLayerId, 'ocean-surface', true),
        (foamLayerId, 'ocean-foam', false),
        if (presentation.hasUnderwater)
          (underwaterLayerId, 'ocean-underwater', false),
      ]) {
        context.registerLayer(
          GeoLayer(
            id: layerId,
            owner: id,
            kind: kind,
            parentId: localId,
            queryable: queryable,
            capabilities: {if (queryable) GeoLayerCapability.query},
            policies: const GeoLayerPolicies(queryWhenHidden: true),
            sourceReference: sampler.coverage.id,
            sourceRevision: sampler.coverage.revision,
            styleRevision: state.revision,
            status: GeoLayerStatus(
              lifecycle: GeoLayerLifecycle.attached,
              data: GeoLayerDataState.loading,
            ),
          ),
        );
      }
      context.provide(oceanSeaState, state);
      context.provide(oceanSampler, sampler);
      context.provide(oceanPresentation, presentation);
    } finally {
      attached.complete();
    }
  }

  @override
  Future<void> beforeGeospatialRender(
    GeospatialContext context,
    FrameInfo frame,
  ) async {
    if (_closed) throw StateError('Ocean attachment closed.');
    bool visible(String layer) =>
        context.layers.findLayer(layer)?.owner == id &&
        context.layers.effectiveVisible(layer);
    try {
      await _presentation!.prepare(
        context.clock.instant,
        frame,
        OceanLayerVisibility(
          surface: visible(surfaceLayerId),
          foam: visible(foamLayerId),
          underwater:
              _presentation!.hasUnderwater && visible(underwaterLayerId),
        ),
      );
      _publish(
        context,
        _presentation!.isReady
            ? GeoLayerDataState.ready
            : GeoLayerDataState.unavailable,
      );
    } catch (_) {
      _publish(context, GeoLayerDataState.failed);
      rethrow;
    }
  }

  void _publish(GeospatialContext context, GeoLayerDataState state) {
    if (_closed || context.sceneContext.scope.isClosed) return;
    final layers = context.layers.snapshot.where((l) => l.owner == id).toList();
    if (_published == state && layers.every((l) => l.status.data == state)) {
      return;
    }
    _published = state;
    context.layers.transact(context.layers.revision, (edit) {
      for (final layer in layers) {
        edit.setStatus(
          layer.id,
          GeoLayerStatus(
            lifecycle: GeoLayerLifecycle.attached,
            data: state,
            failure: state == GeoLayerDataState.failed
                ? const GeoLayerFailure(
                    code: 'ocean_presentation',
                    message:
                        'Ocean presentation failed. Retry the frame or change its configuration.',
                    retryable: true,
                  )
                : null,
          ),
        );
      }
    });
  }

  Future<void> _close() => _closing ??= _closeOwned();
  Future<void> _closeOwned() async {
    _closed = true;
    await _attached?.future;
    final failures = <Object>[];
    try {
      await _presentation?.close();
    } catch (error) {
      failures.add(error);
    }
    try {
      await _sampler?.close();
    } catch (error) {
      failures.add(error);
    }
    _presentation = null;
    _sampler = null;
    if (failures.isNotEmpty) throw ScopeCleanupException(failures);
  }
}
