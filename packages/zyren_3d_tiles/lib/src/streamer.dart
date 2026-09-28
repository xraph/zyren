part of '../zyren_3d_tiles.dart';

final class Tiles3DBudget {
  final int maxRequests,
      maxSelectedTiles,
      maxAttempts,
      maxDecodedBytes,
      maxResidentBytes,
      perTileDecodedBytes,
      perTileResidentBytes;
  Tiles3DBudget({
    this.maxRequests = 4,
    this.maxSelectedTiles = 256,
    this.maxAttempts = 3,
    this.maxDecodedBytes = 64 * 1024 * 1024,
    this.maxResidentBytes = 128 * 1024 * 1024,
    this.perTileDecodedBytes = 4 * 1024 * 1024,
    this.perTileResidentBytes = 8 * 1024 * 1024,
  }) {
    for (final value in [
      maxDecodedBytes,
      maxResidentBytes,
      perTileDecodedBytes,
      perTileResidentBytes,
    ]) {
      RangeError.checkValueInInterval(value, 1, 0x7fffffff);
    }
    RangeError.checkValueInInterval(maxRequests, 1, 64);
    RangeError.checkValueInInterval(maxSelectedTiles, 1, 32768);
    RangeError.checkValueInInterval(maxAttempts, 1, 100);
    if (perTileDecodedBytes > maxDecodedBytes ||
        perTileResidentBytes > maxResidentBytes) {
      throw ArgumentError(
        'A content reservation must fit the streaming budget.',
      );
    }
  }
}

final class Tiles3DStats {
  final int selectedTiles,
      visibleTiles,
      activeRequests,
      cachedBytes,
      reservedBytes,
      residentBytes;
  final bool budgetLimited;
  const Tiles3DStats._(
    this.selectedTiles,
    this.visibleTiles,
    this.activeRequests,
    this.cachedBytes,
    this.reservedBytes,
    this.residentBytes,
    this.budgetLimited,
  );
  Object get _values => (
    selectedTiles,
    visibleTiles,
    activeRequests,
    cachedBytes,
    reservedBytes,
    residentBytes,
    budgetLimited,
  );
}

final class TileFailure3D {
  final String tileId;
  final AssetLoadError code;
  final int attempts;
  const TileFailure3D._(this.tileId, this.code, this.attempts);
  @override
  String toString() => 'Tile $tileId failed (${code.name}, attempt $attempts).';
}

/// CPU content owner. Visible groups belong to this streamer until replacement,
/// eviction or disposal; attach them to only one scene at a time.
class Tiles3DStreamer {
  Tileset3D _tileset;
  Tileset3D get tileset => _tileset;
  final AssetServices services;
  final Tiles3DBudget budget;
  final GltfOptions options;
  final double maximumScreenError;
  final void Function()? onChanged;
  final DateTime Function() _clock;
  final _cache = <String, _LoadedTile>{};
  final _active = <_TileRequest>{};
  final _failures = <String, TileFailure3D>{}, _attempts = <String, int>{};
  Map<String, TileNode3D> _selected = {};
  Map<String, List<TileNode3D>> _branches = {};
  Map<String, Group> _visible = {};
  bool _budgetLimited = false, _disposed = false, _notificationPending = false;
  int _generation = 0;
  Future<void>? _closing;
  Camera? _lastCamera;
  ViewportMetrics? _lastViewport;
  Tiles3DStreamer({
    required Tileset3D tileset,
    required this.services,
    Tiles3DBudget? budget,
    this.options = const GltfOptions(),
    this.maximumScreenError = 8,
    this.onChanged,
    DateTime Function()? clock,
  }) : _tileset = tileset,
       _clock = clock ?? DateTime.now,
       budget = budget ?? Tiles3DBudget() {
    services.limits.validate();
    options.limits.validate();
    if (!maximumScreenError.isFinite || maximumScreenError <= 0) {
      throw ArgumentError('Screen error must be positive.');
    }
  }
  Map<String, Group> get visible => Map.unmodifiable(_visible);

  /// Read-only selection for bounds, hierarchy and request diagnostics.
  Map<String, TileNode3D> get selected => Map.unmodifiable(_selected);

  /// Sorted and deduplicated source credits for the geometry currently visible.
  List<String> get attributions {
    final values = <String>{};
    for (final id in _visible.keys) {
      final copyright = _cache[id]?.content.model?.copyright;
      if (copyright == null) continue;
      values.addAll(
        copyright.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty),
      );
    }
    return List.unmodifiable(values.toList()..sort());
  }

  List<TileFailure3D> get failures => List.unmodifiable(_failures.values);
  int get _cachedBytes =>
      _cache.values.fold(0, (n, e) => n + e.content.decodedBytes);
  int get _reservedBytes => _active.length * budget.perTileDecodedBytes;
  Tiles3DStats get stats => Tiles3DStats._(
    _selected.length,
    _visible.length,
    _active.length,
    _cachedBytes,
    _reservedBytes,
    _visible.keys.fold(0, (n, id) => n + _cache[id]!.content.residentBytes),
    _budgetLimited,
  );

  void update(Camera camera, ViewportMetrics viewport) {
    _checkOpen();
    if (!viewport.isUsable) return;
    _lastCamera = camera;
    _lastViewport = viewport;
    final before = stats._values;
    final selectedBefore = _selected, visibleBefore = _visible;
    _discardInactive();
    final failuresBefore = _failures.length;
    final previous = _branches.keys.toSet();
    final nodes = <String, TileNode3D>{},
        branches = <String, List<TileNode3D>>{};
    var cpu = 0, gpu = 0;
    _budgetLimited = false;
    bool admit(List<TileNode3D> group) {
      var groupCpu = 0, groupGpu = 0;
      for (final node in group) {
        if (node.contentUri == null) continue;
        final cached = _cache[node.id]?.content;
        groupCpu += cached?.decodedBytes ?? budget.perTileDecodedBytes;
        groupGpu += cached?.residentBytes ?? budget.perTileResidentBytes;
      }
      if (nodes.length + group.length > budget.maxSelectedTiles ||
          cpu + groupCpu > budget.maxDecodedBytes ||
          gpu + groupGpu > budget.maxResidentBytes) {
        _budgetLimited = true;
        return false;
      }
      cpu += groupCpu;
      gpu += groupGpu;
      for (final node in group) {
        nodes[node.id] = node;
      }
      return true;
    }

    final root = tileset.root;
    final queue = <TileNode3D>[];
    if (root.bounds.isVisible(camera, viewport) &&
        root.bounds.screenError(tileset.geometricError, camera, viewport) >
            maximumScreenError &&
        admit([root])) {
      queue.add(root);
    }
    while (queue.isNotEmpty) {
      queue.sort((a, b) {
        final error = b.bounds
            .screenError(b.geometricError, camera, viewport)
            .compareTo(
              a.bounds.screenError(a.geometricError, camera, viewport),
            );
        return error == 0 ? a.id.compareTo(b.id) : error;
      });
      final node = queue.removeAt(0);
      final external = _cache[node.id]?.content.hierarchy;
      if (node.children.isEmpty && external == null) continue;
      final threshold =
          maximumScreenError * (previous.contains(node.id) ? 0.8 : 1);
      if (external == null &&
          node.contentUri != null &&
          node.bounds.screenError(node.geometricError, camera, viewport) <=
              threshold) {
        continue;
      }
      final children =
          (external == null
                  ? node.children
                  : node._implicit != null ||
                        external.root.bounds.screenError(
                              external.geometricError,
                              camera,
                              viewport,
                            ) >
                            maximumScreenError
                  ? [external.root]
                  : <TileNode3D>[])
              .where((n) => n.bounds.isVisible(camera, viewport))
              .toList();
      if (!admit(children)) continue;
      branches[node.id] = children;
      queue.addAll(children);
    }
    _selected = nodes;
    _discardInactive();
    _branches = branches;
    for (final request in _active) {
      if (!nodes.containsKey(request.node.id)) {
        request.cancelled = true;
        request.task.cancel();
      }
    }
    _failures.removeWhere((id, _) => !nodes.containsKey(id));
    _attempts.removeWhere((id, _) => !nodes.containsKey(id));
    for (final id in nodes.keys) {
      final value = _cache.remove(id);
      if (value != null) _cache[id] = value;
    }
    _refresh();
    _pump();
    bool sameKeys(Map<String, Object> a, Map<String, Object> b) =>
        a.length == b.length && a.keys.every(b.containsKey);
    if (before != stats._values ||
        failuresBefore != _failures.length ||
        !sameKeys(selectedBefore, _selected) ||
        !sameKeys(visibleBefore, _visible)) {
      _notify();
    }
  }

  void replaceTileset(Tileset3D tileset) {
    _checkOpen();
    _generation++;
    for (final request in _active) {
      request.cancelled = true;
      request.task.cancel();
    }
    _tileset = tileset;
    for (final entry in _cache.values) {
      unawaited(entry.scope.close());
    }
    _cache.clear();
    _selected = {};
    _branches = {};
    _visible = {};
    _failures.clear();
    _attempts.clear();
    _lastCamera = null;
    _lastViewport = null;
    _notify();
  }

  void retryFailed() {
    _checkOpen();
    _failures.removeWhere(
      (_, failure) => failure.attempts < budget.maxAttempts,
    );
    _pump();
  }

  void _pump() {
    if (_disposed) return;
    for (final node in _selected.values) {
      if (_active.length >= budget.maxRequests) break;
      if (node.contentUri == null ||
          _cache.containsKey(node.id) ||
          _failures.containsKey(node.id) ||
          _active.any(
            (r) => r.generation == _generation && r.node.id == node.id,
          )) {
        continue;
      }
      while (_cachedBytes + _reservedBytes + budget.perTileDecodedBytes >
          budget.maxDecodedBytes) {
        final unused = _cache.keys.where((id) => !_selected.containsKey(id));
        if (unused.isEmpty) break;
        _evict(unused.first);
      }
      if (_cachedBytes + _reservedBytes + budget.perTileDecodedBytes >
          budget.maxDecodedBytes) {
        continue;
      }
      final tracker = _TrackedResolver(
        services.resolver,
        tileset.sourceUri,
        _clock,
      );
      final limits = services.limits;
      final scope = AssetScope(
        services: AssetServices(
          resolver: tracker,
          imageDecoder: services.imageDecoder,
          textureDecoder: services.textureDecoder,
          bufferDecoder: services.bufferDecoder,
          meshDecoder: services.meshDecoder,
          policy: services.policy,
          onCleanupError: services.onCleanupError,
          limits: AssetLimits(
            maxSourceBytes: limits.maxSourceBytes,
            maxTotalSourceBytes: limits.maxTotalSourceBytes,
            maxSources: limits.maxSources,
            maxDecodedBytes: math.min(
              limits.maxDecodedBytes,
              budget.perTileDecodedBytes,
            ),
            images: limits.images,
            meshes: limits.meshes,
          ),
        ),
      );
      final request = _TileRequest(
        node,
        _generation,
        scope,
        tracker,
        scope.load(
          AssetRequest(
            uri: node.contentUri!,
            loader: _StreamContentLoader(
              node,
              tileset._limits,
              options,
              tracker.track,
            ),
          ),
        ),
      );
      _active.add(request);
      _attempts[node.id] = (_attempts[node.id] ?? 0) + 1;
      unawaited(_load(request));
    }
  }

  bool _accepts(_TileRequest r) =>
      !_disposed &&
      r.generation == _generation &&
      _selected.containsKey(r.node.id) &&
      !r.cancelled;
  Future<void> _load(_TileRequest request) async {
    var retained = false, hierarchyChanged = false;
    try {
      final content = await request.task.result;
      if (!_accepts(request)) return;
      if (content.decodedBytes > budget.perTileDecodedBytes ||
          content.residentBytes > budget.perTileResidentBytes) {
        _limit();
      }
      final group = content.model?.instantiate(
        transform: request.node.transform,
      );
      _cache[request.node.id] = _LoadedTile(
        request.scope,
        content,
        group,
        request.tracker.freshness,
      );
      hierarchyChanged = content.hierarchy != null;
      retained = true;
    } catch (error) {
      if (_accepts(request) && error is! LoadCancelled) {
        _failures[request.node.id] = TileFailure3D._(
          request.node.id,
          error is AssetLoadException
              ? error.code
              : AssetLoadError.decodeFailed,
          _attempts[request.node.id]!,
        );
      }
    } finally {
      if (!retained) await request.scope.close();
      // Consumer cancellation completes immediately. Physical I/O and a decoder
      // may still be running, so they retain their slot and byte reservation.
      await request.tracker.drain();
      _active.remove(request);
      request.done.complete();
      if (!_disposed) {
        if (hierarchyChanged && _lastCamera != null && _lastViewport != null) {
          update(_lastCamera!, _lastViewport!);
        } else {
          _refresh();
          _pump();
        }
        _notify();
      }
    }
  }

  void _refresh() {
    (bool, Map<String, Group>) coverage(TileNode3D node) {
      final own = _cache[node.id];
      final group = own?.group;
      final children = _branches[node.id];
      if (children != null) {
        var complete = true;
        final found = <String, Group>{};
        for (final child in children) {
          final result = coverage(child);
          complete = complete && result.$1;
          found.addAll(result.$2);
        }
        if (node.refinement == TileRefinement.replace && complete) {
          return (true, found);
        }
        if (node.refinement == TileRefinement.add) {
          return (
            complete && (node.contentUri == null || own != null),
            {node.id: ?group, ...found},
          );
        }
      }
      if (group != null) return (true, {node.id: group});
      return (
        node.contentUri == null && node.children.isEmpty,
        <String, Group>{},
      );
    }

    _visible = _selected.containsKey(tileset.root.id)
        ? coverage(tileset.root).$2
        : {};
  }

  void _evict(String id) {
    final entry = _cache.remove(id);
    if (entry == null) return;
    unawaited(entry.scope.close());
    final hierarchy = entry.content.hierarchy;
    if (hierarchy == null) return;
    // A refreshed document may assign a new URI or transform to the same ID.
    // Retire the descendants with the metadata that defined their identity.
    void retire(TileNode3D node) {
      _evict(node.id);
      for (final child in node.children) {
        retire(child);
      }
    }

    retire(hierarchy.root);
  }

  void _discardInactive() {
    final now = _clock();
    final provider = services.resolver is Tiles3DProviderSession;
    final discard = _cache.entries
        .where(
          (entry) =>
              !_selected.containsKey(entry.key) &&
              (provider || !entry.value.freshness.reusable(now)),
        )
        .map((entry) => entry.key)
        .toList();
    for (final id in discard) {
      _evict(id);
    }
  }

  void _notify() {
    if (_notificationPending || _disposed) return;
    _notificationPending = true;
    scheduleMicrotask(() {
      _notificationPending = false;
      if (!_disposed) onChanged?.call();
    });
  }

  Future<void> dispose() {
    if (_closing case final closing?) return closing;
    _disposed = true;
    for (final request in _active) {
      request.cancelled = true;
      request.task.cancel();
    }
    final waits = [
      for (final entry in _cache.values) entry.scope.close(),
      for (final request in _active) request.done.future,
    ];
    _cache.clear();
    _visible = {};
    _selected = {};
    _branches = {};
    _failures.clear();
    _attempts.clear();
    return _closing = Future.wait(waits).then((_) {});
  }

  void _checkOpen() {
    if (_disposed) throw StateError('3D Tiles streamer is disposed.');
  }
}

final class _LoadedTile {
  final AssetScope scope;
  final _StreamContent content;
  final Group? group;
  final _TileFreshness freshness;
  const _LoadedTile(this.scope, this.content, this.group, this.freshness);
}

final class _TileRequest {
  final TileNode3D node;
  final int generation;
  final AssetScope scope;
  final _TrackedResolver tracker;
  final LoadTask<_StreamContent> task;
  final done = Completer<void>();
  bool cancelled = false;
  _TileRequest(this.node, this.generation, this.scope, this.tracker, this.task);
}

final class _TrackedResolver implements ByteSourceResolver {
  final ByteSourceResolver delegate;
  final Uri sourceUri;
  final _pending = <Future<void>>{};
  final DateTime Function() clock;
  final freshness = _TileFreshness();
  _TrackedResolver(this.delegate, this.sourceUri, this.clock);
  void track(Future<void> future) {
    late final Future<void> settled;
    settled = future
        .then<void>((_) {}, onError: (Object _, StackTrace _) {})
        .whenComplete(() => _pending.remove(settled));
    _pending.add(settled);
  }

  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) {
    final future = Future.sync(() async {
      context.policy.validate(sourceUri, uri);
      final result = await delegate.read(uri, context);
      freshness.include(result.headers, clock());
      return result;
    });
    track(future.then<void>((_) {}));
    return future;
  }

  Future<void> drain() async {
    while (_pending.isNotEmpty) {
      await Future.wait(_pending.toList());
    }
  }
}
