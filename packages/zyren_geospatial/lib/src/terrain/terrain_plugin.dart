import 'dart:async';
import 'package:zyren/zyren.dart';
import '../geospatial_plugin.dart';
import '../tiling.dart';
import '../streaming/tile_source.dart';
import '../streaming/tile_scheduler.dart';
import 'terrain_tile.dart';

/// Streams regional terrain through ordinary core meshes and color textures.
class TerrainPlugin extends ScenePlugin {
  TerrainSource _source;
  TerrainSource get source => _source;
  final TileBudget budget;
  final double maximumScreenError;

  /// Asynchronous loading/count updates, independent of sampled GPU statistics.
  final void Function(TileStreamingStats)? onChanged;
  TileScheduler<TerrainTile>? _scheduler;
  PluginContext? _context;
  Group? _group;
  final _meshes = <TileCoordinate, (TerrainTile, Mesh)>{};
  Object? _lastStats;
  bool _notificationPending = false;
  TerrainPlugin({
    required TerrainSource source,
    TileBudget? budget,
    this.maximumScreenError = 8,
    this.onChanged,
  }) : _source = source,
       budget = budget ?? TileBudget();
  @override
  String get id => 'geospatial.terrain';
  @override
  Set<String> get dependencies => {GeospatialPlugin.pluginId};
  TileStreamingStats? get stats => _scheduler?.stats;
  Set<TileCoordinate> get visibleCoordinates =>
      Set.unmodifiable(_scheduler?.visible.keys ?? const []);
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
    _group = Group(name: 'Terrain');
    context.scene.add(_group!);
  }

  void replaceSource(TerrainSource source) {
    final context = _context;
    if (context != null) {
      _validateSource(source, context);
      _scheduler!.replaceSource(source);
      _syncMeshes();
      context.invalidate();
    }
    _source = source;
  }

  void retryFailed() {
    _scheduler?.retryFailed();
    _context?.invalidate();
  }

  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
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
      }
    }
    for (final entry in next.entries) {
      if (!identical(_meshes[entry.key]?.$2, entry.value.$2)) {
        _group!.add(entry.value.$2);
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
    _group = null;
    _context = null;
    _lastStats = null;
    _notificationPending = false;
  }
}
