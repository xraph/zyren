import 'dart:async';
import 'package:zyren/zyren.dart';
import '../geospatial_plugin.dart';
import '../tiling.dart';
import '../streaming/tile_source.dart';
import '../streaming/tile_scheduler.dart';
import 'terrain_tile.dart';
import 'imagery_terrain_source.dart';

/// Streams regional terrain through ordinary core meshes and color textures.
class TerrainPlugin extends ScenePlugin {
  final String instanceId;
  final Set<String> additionalDependencies;
  TerrainSource _source;
  TerrainSource get source => _source;
  final TileBudget budget;
  final double maximumScreenError;

  /// Asynchronous loading/count updates, independent of sampled GPU statistics.
  final void Function(TileStreamingStats)? onChanged;
  TileScheduler<TerrainTile>? _scheduler;
  PluginContext? _context;
  Group? _group;
  Group? get group => _group;
  bool visible = true;
  bool retainWhenHidden = true;
  bool _releasedHidden = false;
  int _imageryRevision = 0;
  bool get retainingPreviousSource =>
      _scheduler?.retainingPreviousSource ?? false;
  final _queryScene = Scene();
  final _queryCoordinates = <Mesh, TileCoordinate>{};
  final _raycaster = Raycaster();
  bool _queryDirty = true;
  final _meshes = <TileCoordinate, (TerrainTile, Mesh)>{};
  Object? _lastStats;
  bool _notificationPending = false;
  TerrainPlugin({
    required TerrainSource source,
    this.instanceId = 'geospatial.terrain',
    Set<String> additionalDependencies = const {},
    TileBudget? budget,
    this.maximumScreenError = 8,
    this.onChanged,
  }) : additionalDependencies = Set.unmodifiable(additionalDependencies),
       _source = source,
       budget = budget ?? TileBudget();
  @override
  String get id => instanceId;
  @override
  Set<String> get dependencies => {
    GeospatialPlugin.pluginId,
    ...additionalDependencies,
  };
  TileStreamingStats? get stats => _scheduler?.stats;
  Set<TileCoordinate> get visibleCoordinates =>
      Set.unmodifiable(_scheduler?.visible.keys ?? const []);
  List<String> get attributions => List.unmodifiable(
    ({
      for (final tile in _scheduler?.visible.values ?? <TerrainTile>[])
        ...tile.attributions,
    }.toList()..sort()),
  );
  List<TileFailure> get failures => _scheduler?.failures ?? const [];

  void _validateSource(TerrainSource source, PluginContext context) {
    final shared = context.service(geospatialReference).ellipsoid;
    final supplied = source.ellipsoid;
    if (shared.x != supplied.x ||
        shared.y != supplied.y ||
        shared.z != supplied.z) {
      throw ArgumentError(
        'Terrain and geospatial plugins must use the same ellipsoid.',
      );
    }
  }

  @override
  void attach(PluginContext context) {
    _validateSource(_source, context);
    final scheduler = TileScheduler<TerrainTile>(
      source: _source,
      budget: budget,
      maximumScreenError: maximumScreenError,
      onChanged: () {
        context.invalidate();
        _notifyChanged();
      },
    );
    _scheduler = scheduler;
    _context = context;
    _group = Group(name: 'Terrain $id')..visible = visible;
    context.scene.add(_group!);
  }

  void replaceSource(TerrainSource source, {bool retainVisible = false}) {
    final context = _context;
    if (context != null) {
      _validateSource(source, context);
      _scheduler!.replaceSource(source, retainVisible: retainVisible);
      _syncMeshes();
      context.invalidate();
    }
    _source = source;
  }

  /// Recomposition uses an immutable source and cancels obsolete load generations.
  void setImageryStack(
    List<ImageryLayer> layers, {
    required int revision,
    int outputSize = 256,
    int maxTilesPerLayer = 4,
    TerrainSource? terrain,
  }) {
    if (revision <= _imageryRevision) {
      throw StateError('Imagery revision must increase.');
    }
    final base =
        terrain ??
        (_source is ImageryTerrainSource
            ? (_source as ImageryTerrainSource).terrain
            : _source);
    final next = layers.isEmpty
        ? base
        : ImageryTerrainSource(
            terrain: base,
            layers: layers,
            outputSize: outputSize,
            maxTilesPerLayer: maxTilesPerLayer,
          );
    replaceSource(next, retainVisible: true);
    _imageryRevision = revision;
  }

  /// Queries loaded geometry independently of the rendered group's visibility.
  List<({TileCoordinate coordinate, PickResult hit})> pick(CameraRay ray) {
    if (_context == null) return const [];
    if (_queryDirty) {
      for (final child in _queryScene.children.toList()) {
        _queryScene.remove(child);
      }
      _queryCoordinates.clear();
      for (final entry in _meshes.entries) {
        final original = entry.value.$2;
        final mesh = Mesh(original.geometry, original.material)
          ..position = original.position;
        _queryScene.add(mesh);
        _queryCoordinates[mesh] = entry.key;
      }
      _queryDirty = false;
    }
    return [
      for (final hit in _raycaster.intersectScene(_queryScene, ray))
        (coordinate: _queryCoordinates[hit.object]!, hit: hit),
    ];
  }

  void retryFailed() {
    _scheduler?.retryFailed();
    _context?.invalidate();
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    _group!.visible = visible;
    if (!visible) {
      if (!retainWhenHidden && !_releasedHidden) {
        _scheduler!.replaceSource(_source);
        _syncMeshes();
        _releasedHidden = true;
      }
      return;
    }
    _releasedHidden = false;
    final input = context.input;
    final viewport = input is ViewportInputSource
        ? input.viewport
        : ViewportMetrics(frame.width.toDouble(), frame.height.toDouble());
    _scheduler!.update(context.camera, viewport);
    _syncMeshes();
    _notifyChanged();
  }

  void _notifyChanged() {
    final current = stats;
    final context = _context;
    if (current == null || context == null || onChanged == null) return;
    final key = (
      current.selectedTiles,
      current.visibleTiles,
      current.activeRequests,
      current.cachedBytes,
      current.reservedBytes,
      current.residentBytes,
      current.budgetLimited,
      failures.length,
      _source.identity,
      retainingPreviousSource,
    );
    if (key == _lastStats) return;
    _lastStats = key;
    if (_notificationPending) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      if (!identical(_context, context)) return;
      _notificationPending = false;
      onChanged?.call(stats!);
    });
  }

  void _syncMeshes() {
    final visible = _scheduler!.visible;
    // Construct the complete next set before changing the submitted scene.
    final next = <TileCoordinate, (TerrainTile, Mesh)>{};
    for (final entry in visible.entries) {
      final old = _meshes[entry.key];
      if (old != null && identical(old.$1, entry.value)) {
        next[entry.key] = old;
      } else {
        final tile = entry.value;
        final mesh = Mesh(
          tile.geometry,
          DiffuseMaterial(
            colorMap: TextureMap(image: tile.imagery, sampler: tile.sampler),
          ),
          name: 'Terrain ${entry.key.z}/${entry.key.x}/${entry.key.y}',
        )..position = tile.origin;
        next[entry.key] = (tile, mesh);
      }
    }
    for (final entry in _meshes.entries) {
      if (!identical(next[entry.key]?.$2, entry.value.$2)) {
        _group!.remove(entry.value.$2);
        _queryDirty = true;
      }
    }
    for (final entry in next.entries) {
      if (!identical(_meshes[entry.key]?.$2, entry.value.$2)) {
        _group!.add(entry.value.$2);
        _queryDirty = true;
      }
    }
    _meshes
      ..clear()
      ..addAll(next);
  }

  @override
  void detach(PluginContext context) {
    _scheduler?.dispose();
    _scheduler = null;
    final group = _group;
    if (group != null) {
      context.scene.remove(group);
      for (final mesh in _meshes.values) {
        group.remove(mesh.$2);
      }
    }
    _meshes.clear();
    for (final child in _queryScene.children.toList()) {
      _queryScene.remove(child);
    }
    _queryCoordinates.clear();
    _raycaster.clearCache();
    _queryDirty = true;
    _releasedHidden = false;
    _group = null;
    _context = null;
    _lastStats = null;
    _notificationPending = false;
  }
}
