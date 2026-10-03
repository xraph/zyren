part of '../zyren_3d_tiles.dart';

// Lowest comparator value wins, matching the previous sorted-list order.
final class _TilePriorityQueue<T> {
  final int Function(T, T) compare;
  final _items = <T>[];
  _TilePriorityQueue(this.compare);
  bool get isNotEmpty => _items.isNotEmpty;
  void addAll(Iterable<T> values) {
    for (final value in values) {
      add(value);
    }
  }

  void add(T value) {
    var index = _items.length;
    _items.add(value);
    while (index > 0) {
      final parent = (index - 1) ~/ 2;
      if (compare(value, _items[parent]) >= 0) break;
      _items[index] = _items[parent];
      index = parent;
    }
    _items[index] = value;
  }

  T removeFirst() {
    final first = _items.first, last = _items.removeLast();
    if (_items.isEmpty) return first;
    var index = 0;
    while (index * 2 + 1 < _items.length) {
      var child = index * 2 + 1;
      if (child + 1 < _items.length &&
          compare(_items[child + 1], _items[child]) < 0) {
        child++;
      }
      if (compare(last, _items[child]) <= 0) break;
      _items[index] = _items[child];
      index = child;
    }
    _items[index] = last;
    return first;
  }
}

final class Tiles3DBudget {
  final int maxRequests,
      maxSelectedTiles,
      maxAttempts,
      maxDecodedBytes,
      maxResidentBytes,
      perTileDecodedBytes,
      perTileResidentBytes;
  final int maxPrefetchRequests, maxPrefetchTiles, maxPrefetchBytes;
  Tiles3DBudget({
    this.maxRequests = 4,
    this.maxPrefetchRequests = 0,
    this.maxPrefetchTiles = 8,
    this.maxPrefetchBytes = 8 * 1024 * 1024,
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
    RangeError.checkValueInInterval(maxPrefetchRequests, 0, maxRequests - 1);
    RangeError.checkValueInInterval(maxPrefetchTiles, 0, 256);
    RangeError.checkValueInInterval(maxPrefetchBytes, 0, 0x7fffffff);
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
  final int prefetchedTiles, prefetchBytes, displayedTiles;
  final double effectiveScreenError;
  const Tiles3DStats._(
    this.selectedTiles,
    this.visibleTiles,
    this.activeRequests,
    this.cachedBytes,
    this.reservedBytes,
    this.residentBytes,
    this.budgetLimited,
    this.prefetchedTiles,
    this.prefetchBytes,
    this.displayedTiles,
    this.effectiveScreenError,
  );
  Object get _values => (
    selectedTiles,
    visibleTiles,
    activeRequests,
    cachedBytes,
    reservedBytes,
    residentBytes,
    budgetLimited,
    prefetchedTiles,
    prefetchBytes,
    displayedTiles,
    effectiveScreenError,
  );
}

final class TileFailure3D {
  final String tileId;
  final AssetLoadError code;
  final int attempts;
  final int? httpStatus;
  const TileFailure3D._(this.tileId, this.code, this.attempts, this.httpStatus);
  @override
  String toString() =>
      'Tile $tileId failed (${code.name}, '
      '${httpStatus == null ? '' : 'HTTP $httpStatus, '}attempt $attempts).';
}

/// CPU content owner. Visible groups belong to this streamer until replacement,
/// eviction or disposal; attach them to only one scene at a time.
class Tiles3DStreamer {
  Tileset3D _tileset;
  Tileset3D get tileset => _tileset;
  final AssetServices services;
  final Tiles3DBudget budget;
  final GltfOptions options;
  TileStyle3D? _style;
  TileStyle3D? get style => _style;
  final double maximumScreenError;
  final Duration fadeDuration;
  final TileVisibilityPolicy? visibilityPolicy;
  final _TileMotion? _motion;
  final bool trackPublication;
  Map<String, Group> _displayed = {}, _submitted = {};
  Set<(int, int)> _submittedIdentities = {};
  Map<String, TileNode3D> _prefetch = {};
  final _prefetched = <String>{};
  final _expiredPrefetch = <String>{};
  bool get isAwaitingPublication =>
      trackPublication &&
      (_visible.length != _displayed.length ||
          _visible.entries.any(
            (entry) => !identical(_displayed[entry.key], entry.value),
          ));
  bool get needsUpdate => isTransitioning || (_motion?.pending ?? false);
  double get effectiveScreenError => maximumScreenError * (_motion?.scale ?? 1);
  Map<String, Group> get displayed =>
      Map.unmodifiable(trackPublication ? _displayed : _visible);
  bool _isVisible(TileNode3D node, Camera camera, ViewportMetrics viewport) =>
      node.bounds.isVisible(camera, viewport) &&
      (visibilityPolicy?.call(node.bounds, camera) ?? true);
  final void Function()? onChanged;
  final DateTime Function() _clock;
  final _cache = <String, _LoadedTile>{};
  final _retired = <_LoadedTile>[];
  final _owners = Expando<_LoadedTile>();
  final _featureOwners = Expando<TileModelInstance3D>();
  final _active = <_TileRequest>{};
  final _failures = <String, TileFailure3D>{}, _attempts = <String, int>{};
  Map<String, TileNode3D> _selected = {};
  Map<String, List<TileNode3D>> _branches = {};
  Map<String, Group> _visible = {};
  final _watch = Stopwatch()..start();
  Duration _elapsed = Duration.zero;
  _TileTransition? _transition;
  bool get isTransitioning => _transition != null;
  bool _budgetLimited = false, _disposed = false, _notificationPending = false;
  int _generation = 0;
  Future<void>? _closing;
  Camera? _lastCamera;
  ViewportMetrics? _lastViewport;
  int? _selectionCameraRevision;
  bool _selectionDirty = true;
  final _screenErrors = <TileNode3D, double>{};
  double _screenError(TileNode3D node) => _screenErrors.putIfAbsent(
    node,
    () => node.bounds.screenError(
      node.geometricError,
      _lastCamera!,
      _lastViewport!,
    ),
  );
  Tiles3DStreamer({
    required Tileset3D tileset,
    required this.services,
    Tiles3DBudget? budget,
    this.options = const GltfOptions(),
    TileStyle3D? style,
    this.maximumScreenError = 8,
    this.fadeDuration = Duration.zero,
    this.visibilityPolicy,
    Tiles3DMotionPolicy? motionPolicy,
    this.trackPublication = false,
    this.onChanged,
    DateTime Function()? clock,
  }) : _motion = motionPolicy == null ? null : _TileMotion(motionPolicy),
       _tileset = tileset,
       _style = style,
       _clock = clock ?? DateTime.now,
       budget = budget ?? Tiles3DBudget() {
    motionPolicy?._validate();
    services.limits.validate();
    options.limits.validate();
    if (fadeDuration.isNegative || fadeDuration > const Duration(seconds: 5)) {
      throw ArgumentError(
        'Fade duration must be between zero and five seconds.',
      );
    }
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
    for (final group in displayed.values) {
      final copyright = _owners[group]?.content.model?.copyright;
      if (copyright == null) continue;
      values.addAll(
        copyright.split(';').map((s) => s.trim()).where((s) => s.isNotEmpty),
      );
    }
    return List.unmodifiable(values.toList()..sort());
  }

  List<TileFailure3D> get failures => List.unmodifiable(_failures.values);
  int get _cachedBytes => {
    ..._cache.values.map((e) => e.content),
    ..._retired.map((e) => e.content),
  }.fold(0, (n, e) => n + e.decodedBytes);
  int get _reservedBytes => _active.length * budget.perTileDecodedBytes;
  int get _reservedResidentBytes =>
      _active.length * budget.perTileResidentBytes;
  int get _prefetchBytes =>
      _prefetched.fold(
        0,
        (n, id) => n + (_cache[id]?.content.decodedBytes ?? 0),
      ) +
      _active.where((r) => r.prefetch).length * budget.perTileDecodedBytes;
  final _resourceFootprints = Expando<Map<Object, int>>();
  int _resident(Iterable<Group> groups) {
    final assets = <Object, int>{};
    for (final group in groups) {
      var footprint = _resourceFootprints[group];
      if (footprint == null) {
        footprint = <Object, int>{};
        void visit(Object3D node) {
          if (node is Mesh) {
            footprint![node.geometry] = node.geometry.capture().gpuByteLength;
            for (final map in node.material.textureMaps) {
              final image = map.image;
              footprint[image] = math.max(
                image.descriptor.byteLength,
                image.levels.fold<int>(0, (n, l) => n + l.length),
              );
            }
          }
          for (final child in node.children) {
            visit(child);
          }
        }

        visit(group);
        _resourceFootprints[group] = footprint;
      }
      assets.addAll(footprint);
    }
    return assets.values.fold(0, (a, b) => a + b);
  }

  Tiles3DStats get stats => Tiles3DStats._(
    _selected.length,
    _visible.length,
    _active.length,
    _cachedBytes,
    _reservedBytes,
    _resident({..._visible.values, ..._displayed.values, ..._submitted.values}),
    _budgetLimited,
    _prefetched.length,
    _prefetchBytes,
    displayed.length,
    effectiveScreenError,
  );

  void update(Camera camera, ViewportMetrics viewport, {Duration? elapsed}) {
    _checkOpen();
    if (!viewport.isUsable) return;
    final time = elapsed ?? _watch.elapsed;
    if (time.isNegative) {
      throw ArgumentError('Elapsed time cannot be negative.');
    }
    if (time < _elapsed) _finishTransition();
    _elapsed = time;
    if (_motion?.update(camera, time) ?? false) _selectionDirty = true;
    final sameView =
        identical(camera, _lastCamera) &&
        camera.revision == _selectionCameraRevision &&
        viewport.width == _lastViewport?.width &&
        viewport.height == _lastViewport?.height &&
        viewport.devicePixelRatio == _lastViewport?.devicePixelRatio;
    _lastCamera = camera;
    _lastViewport = viewport;
    final before = stats._values;
    if (sameView && !_selectionDirty) {
      // Animated clouds do not change tile visibility. Keep freshness and
      // refinement fades moving without rebuilding a stationary selection.
      _discardInactive();
      if (!_selectionDirty) {
        final fading = isTransitioning;
        if (fading) {
          _refresh();
          _discardInactive();
          _pump();
        }
        if (fading || before != stats._values) _notify();
        return;
      }
    }
    // Speculative content must still be reusable when it enters the real view.
    // Retire external metadata before traversing identities derived from it.
    for (final id in _prefetched.toList()) {
      final node = _prefetch[id], entry = _cache[id];
      if (node != null &&
          entry != null &&
          !entry.freshness.reusable(_clock()) &&
          _isVisible(node, camera, viewport)) {
        _evict(id);
        _expiredPrefetch.add(id);
      }
    }
    _screenErrors.clear();
    final selectedBefore = _selected, visibleBefore = _visible;
    _discardInactive();
    final failuresBefore = _failures.length;
    final previous = _branches.keys.toSet();
    final nodes = <String, TileNode3D>{},
        branches = <String, List<TileNode3D>>{};
    var cpu = 0;
    _budgetLimited = false;
    bool admit(List<TileNode3D> group) {
      var groupCpu = 0;
      for (final node in group) {
        if (node.contentUri == null) continue;
        final cached = _cache[node.id]?.content;
        // Unknown payloads reserve their full limits when a physical request
        // starts. Charging an entire sibling group here can prevent refinement
        // even when its actual contents fit comfortably in the cache.
        groupCpu += cached?.decodedBytes ?? 0;
      }
      if (nodes.length + group.length > budget.maxSelectedTiles ||
          cpu + groupCpu > budget.maxDecodedBytes) {
        _budgetLimited = true;
        return false;
      }
      cpu += groupCpu;
      for (final node in group) {
        nodes[node.id] = node;
      }
      return true;
    }

    final root = tileset.root;
    final queue = _TilePriorityQueue<TileNode3D>((a, b) {
      final error = _screenError(b).compareTo(_screenError(a));
      return error == 0 ? a.id.compareTo(b.id) : error;
    });
    if (_isVisible(root, camera, viewport) &&
        root.bounds.screenError(tileset.geometricError, camera, viewport) >
            effectiveScreenError &&
        admit([root])) {
      queue.add(root);
    }
    while (queue.isNotEmpty) {
      final node = queue.removeFirst();
      final external = _cache[node.id]?.content.hierarchy;
      if (node.children.isEmpty && external == null) continue;
      final threshold =
          effectiveScreenError * (previous.contains(node.id) ? 0.8 : 1);
      if (external == null &&
          node.contentUri != null &&
          _screenError(node) <= threshold) {
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
                            effectiveScreenError
                  ? [external.root]
                  : <TileNode3D>[])
              .where((n) => _isVisible(n, camera, viewport))
              .toList();
      if (!admit(children)) continue;
      branches[node.id] = children;
      queue.addAll(children);
    }
    _selected = nodes;
    _updatePrefetch(camera, viewport);
    _prefetched.removeAll(nodes.keys);
    _prefetched.addAll(
      _prefetch.keys.where(
        (id) => _cache.containsKey(id) && !_holdsVisible(id),
      ),
    );
    _expiredPrefetch.removeWhere(
      (id) => !_prefetch.containsKey(id) && !nodes.containsKey(id),
    );
    _discardInactive();
    _branches = branches;
    for (final request in _active) {
      final id = request.node.id;
      if (nodes.containsKey(id)) {
        request.prefetch = false;
      } else {
        final mayPrefetch =
            _prefetch.containsKey(id) &&
            (request.prefetch ||
                (_active.where((r) => r.prefetch).length <
                        budget.maxPrefetchRequests &&
                    _prefetchBytes + budget.perTileDecodedBytes <=
                        budget.maxPrefetchBytes));
        if (mayPrefetch) {
          request.prefetch = true;
        } else {
          request.cancelled = true;
          request.task.cancel();
        }
      }
    }
    _failures.removeWhere(
      (id, _) => !nodes.containsKey(id) && !_prefetch.containsKey(id),
    );
    _attempts.removeWhere(
      (id, _) => !nodes.containsKey(id) && !_prefetch.containsKey(id),
    );
    for (final id in nodes.keys) {
      final value = _cache.remove(id);
      if (value != null) _cache[id] = value;
    }
    _refresh();
    _discardInactive();
    _pump();
    _selectionCameraRevision = camera.revision;
    _selectionDirty = false;
    bool sameKeys(Map<String, Object> a, Map<String, Object> b) =>
        a.length == b.length && a.keys.every(b.containsKey);
    if (before != stats._values ||
        failuresBefore != _failures.length ||
        !sameKeys(selectedBefore, _selected) ||
        !sameKeys(visibleBefore, _visible) ||
        isTransitioning) {
      _notify();
    }
  }

  /// Pins the exact candidate whose frame is about to be submitted.
  void beginFrame() {
    _submitted = Map.of(_visible);
    _submittedIdentities = {};
    void visit(Object3D node) {
      if (!node.visible) return;
      if (node is Mesh &&
          (node.layers.intersects(_lastCamera?.layers ?? LayerMask.all))) {
        _submittedIdentities.add((node.id, node.geometry.id));
      }
      for (final child in node.renderChildren) {
        visit(child);
      }
    }

    for (final group in _submitted.values) {
      visit(group);
    }
  }

  /// An absent receipt uses synchronous-renderer compatibility. It does not
  /// establish native upload readiness. Failed frames must not call this method.
  void completeFrame(SceneAdmission? admission) {
    if (admission == null ||
        (admission.candidateReady &&
            admission.presentedIdentities.toSet().containsAll(
              _submittedIdentities,
            ))) {
      _displayed = Map.of(_submitted);
    }
    _submitted = {};
    final held = {
      for (final group in {..._displayed.values, ..._visible.values})
        _owners[group]?.scope,
    };
    _retired.removeWhere((entry) {
      if (held.contains(entry.scope)) return false;
      unawaited(entry.scope.close());
      return true;
    });
    _refresh();
    _discardInactive();
    _pump();
  }

  void _updatePrefetch(Camera camera, ViewportMetrics viewport) {
    _prefetch = {};
    final motion = _motion;
    if (motion == null ||
        budget.maxPrefetchRequests == 0 ||
        budget.maxPrefetchTiles == 0) {
      return;
    }
    final adjacent = motion._cameraCopy(camera, camera.position, camera.target);
    if (adjacent is PerspectiveCamera) {
      adjacent.fieldOfView = math.min(
        math.pi - .01,
        adjacent.fieldOfView * motion.policy.adjacentScale,
      );
    } else if (adjacent is OrthographicCamera) {
      adjacent.zoom /= motion.policy.adjacentScale;
    }
    final views = [if (motion.predicted != null) motion.predicted!, adjacent];
    final queue = <TileNode3D>[tileset.root];
    var visited = 0, decoded = 0;
    for (
      var i = 0;
      i < queue.length && visited++ < budget.maxSelectedTiles;
      i++
    ) {
      final node = queue[i];
      final view = views
          .where((v) => _isVisible(node, v, viewport))
          .firstOrNull;
      if (view == null) continue;
      final external = _cache[node.id]?.content.hierarchy;
      final children = external == null ? node.children : [external.root];
      if (children.isNotEmpty &&
          (node.contentUri == null ||
              external != null ||
              node.bounds.screenError(node.geometricError, view, viewport) >
                  effectiveScreenError)) {
        queue.addAll(children);
      }
      if (!_selected.containsKey(node.id) && node.contentUri != null) {
        final bytes = _holdsVisible(node.id)
            ? 0
            : (_cache[node.id]?.content.decodedBytes ?? 0);
        if (decoded + bytes > budget.maxPrefetchBytes) continue;
        decoded += bytes;
        _prefetch[node.id] = node;
        if (_prefetch.length >= budget.maxPrefetchTiles) break;
      }
    }
    // Fresh inactive prefetch still counts against its separate allowance.
    for (final id in _prefetched.toList()) {
      if (!_prefetch.containsKey(id) &&
          !_selected.containsKey(id) &&
          !_holdsVisible(id)) {
        _evict(id);
      }
    }
  }

  void replaceTileset(Tileset3D tileset) {
    _checkOpen();
    _finishTransition();
    _generation++;
    for (final request in _active) {
      request.cancelled = true;
      request.task.cancel();
    }
    _tileset = tileset;
    final retainedScopes = {
      for (final group in {..._displayed.values, ..._submitted.values})
        _owners[group]?.scope,
    };
    for (final entry in _cache.values) {
      if (trackPublication && retainedScopes.contains(entry.scope)) {
        _retired.add(entry);
      } else {
        unawaited(entry.scope.close());
      }
    }
    _cache.clear();
    _selected = {};
    _branches = {};
    _visible = {};
    if (!trackPublication) {
      _displayed = {};
      _submitted = {};
    }
    _prefetch = {};
    _prefetched.clear();
    _expiredPrefetch.clear();
    _failures.clear();
    _attempts.clear();
    _lastCamera = null;
    _lastViewport = null;
    _selectionCameraRevision = null;
    _selectionDirty = true;
    _screenErrors.clear();
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
    for (final node in [..._selected.values, ..._prefetch.values]) {
      if (_active.length >= budget.maxRequests) break;
      if (node.contentUri == null ||
          _cache.containsKey(node.id) ||
          _failures.containsKey(node.id) ||
          _active.any(
            (r) => r.generation == _generation && r.node.id == node.id,
          )) {
        continue;
      }
      final prefetch = !_selected.containsKey(node.id);
      if (prefetch &&
          (_expiredPrefetch.contains(node.id) ||
              _active.where((r) => r.prefetch).length >=
                  budget.maxPrefetchRequests ||
              _prefetchBytes + budget.perTileDecodedBytes >
                  budget.maxPrefetchBytes)) {
        continue;
      }
      bool hasRoom() =>
          _cachedBytes + _reservedBytes + budget.perTileDecodedBytes <=
              budget.maxDecodedBytes &&
          _reservedResidentBytes + budget.perTileResidentBytes <=
              budget.maxResidentBytes;
      while (!hasRoom()) {
        final unused = _cache.keys.where(
          (id) =>
              !_selected.containsKey(id) &&
              !_holdsVisible(id) &&
              (!prefetch || !_prefetch.containsKey(id)),
        );
        if (unused.isEmpty) break;
        _evict(unused.first);
      }
      if (!hasRoom()) {
        _budgetLimited = true;
        // Every request reserves the same limits. After unused tiles have been
        // evicted, later nodes cannot fit either. Avoid rescanning the full
        // cache for each blocked node on every animated frame.
        break;
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
      request.prefetch = prefetch;
      _active.add(request);
      _attempts[node.id] = (_attempts[node.id] ?? 0) + 1;
      unawaited(_load(request));
    }
  }

  /// Applies to all cached instances and future arrivals. Callback failure leaves
  /// every cached instance and the current style unchanged.
  void setStyle(TileStyle3D? style) {
    if (_disposed) throw StateError('The tile streamer is disposed.');
    final edits = <_StyleEdit>[];
    final replacements = <String, _LoadedTile>{};
    for (final entry in _cache.entries) {
      final group = entry.value.group;
      if (group == null) continue;
      if (trackPublication) {
        final copy = entry.value.content.model!.instantiate(
          transform: group._matrix,
        );
        edits.addAll(copy._prepareStyle(style));
        replacements[entry.key] = _LoadedTile(
          entry.value.scope,
          entry.value.content,
          copy,
          entry.value.freshness,
        );
      } else {
        edits.addAll(group._prepareStyle(style));
      }
    }
    _applyStyle(edits);
    for (final entry in replacements.entries) {
      _cache[entry.key] = entry.value;
      _indexFeatures(entry.value);
    }
    _style = style;
    if (trackPublication) _refresh();
    _notify();
  }

  TileFeature3D? featureFor(
    PickResult pick, {
    int featureSet = 0,
    String? featureLabel,
  }) {
    final capturedOwner = _featureOwners[pick.object];
    if (capturedOwner != null) {
      return capturedOwner.featureFor(
        pick,
        featureSet: featureSet,
        featureLabel: featureLabel,
      );
    }
    for (final group in displayed.values) {
      final feature = (group as TileModelInstance3D).featureFor(
        pick,
        featureSet: featureSet,
        featureLabel: featureLabel,
      );
      if (feature != null) return feature;
    }
    return null;
  }

  void _indexFeatures(_LoadedTile entry) {
    final group = entry.group;
    if (group == null) return;
    _owners[group] = entry;
    final credits =
        (entry.content.model?.copyright ?? '')
            .split(';')
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toSet()
            .toList()
          ..sort();
    for (final feature in group.features) {
      feature._attributions = List.unmodifiable(credits);
      for (final mesh in feature._meshes) {
        _featureOwners[mesh] = group;
      }
    }
  }

  bool _accepts(_TileRequest r) =>
      !_disposed &&
      r.generation == _generation &&
      (_selected.containsKey(r.node.id) || _prefetch.containsKey(r.node.id)) &&
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
      group?.setStyle(_style);
      _cache[request.node.id] = _LoadedTile(
        request.scope,
        content,
        group,
        request.tracker.freshness,
      );
      _indexFeatures(_cache[request.node.id]!);
      if (!_selected.containsKey(request.node.id)) {
        _prefetched.add(request.node.id);
      }
      _selectionDirty = true;
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
          error is AssetLoadException ? error.httpStatus : null,
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
          update(_lastCamera!, _lastViewport!, elapsed: _elapsed);
        } else {
          _refresh();
          _pump();
        }
        _notify();
      }
    }
  }

  void _refresh() {
    // Build a coarse cover first. Cached ancestors stay in CPU memory; only
    // groups in the published cover consume the visible residency allowance.
    (bool, Map<String, Group>) coverage(TileNode3D node) {
      final own = _cache[node.id];
      final group = own?.group;
      if (group != null && node.refinement == TileRefinement.replace) {
        return (true, {node.id: group});
      }
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

    int bytes(Map<String, Group> groups) => _resident(groups.values);
    var desired = _selected.containsKey(tileset.root.id)
        ? coverage(tileset.root).$2
        : <String, Group>{};
    if (bytes(desired) > budget.maxResidentBytes) {
      _budgetLimited = true;
      final root = _cache[tileset.root.id]?.group;
      desired = {tileset.root.id: ?root};
    }
    final coarse = Map<String, Group>.of(desired);
    double error(String id) {
      final node = _selected[id];
      return node == null ? 0 : _screenError(node);
    }

    final pending = _TilePriorityQueue<String>((a, b) {
      final order = error(b).compareTo(error(a));
      return order == 0 ? a.compareTo(b) : order;
    })..addAll(desired.keys);
    final expanded = <String>{};
    while (pending.isNotEmpty) {
      final id = pending.removeFirst();
      if (!desired.containsKey(id) || !expanded.add(id)) continue;
      final node = _selected[id];
      if (node == null) continue;
      final children = _branches[id];
      if (children == null) continue;
      var complete = true;
      final found = <String, Group>{};
      for (final child in children) {
        final result = coverage(child);
        complete = complete && result.$1;
        found.addAll(result.$2);
      }
      final replace = node.refinement == TileRefinement.replace;
      if (replace && !complete) continue;
      final next = {...desired};
      if (replace) next.remove(id);
      next.addAll(found);
      final nextBytes = bytes(next);
      if (nextBytes > budget.maxResidentBytes) {
        _budgetLimited = true;
        continue;
      }
      // Publish a whole replacement together. Partial siblings cannot remove
      // their fallback, even when the remaining requests failed or were denied.
      if (replace) desired.remove(id);
      desired.addAll(found);

      pending.addAll(found.keys.where((key) => !expanded.contains(key)));
    }
    if (trackPublication) {
      // Keep enough room for a complete coarse bridge while refining. This is
      // headroom within the existing allowance, not an increased resource cap.
      final bridge = coarse;
      final bridgeFitsDetail =
          bytes({...bridge, ...desired}) <= budget.maxResidentBytes;
      final overlapFits =
          _resident({..._displayed.values, ...desired.values}) <=
          budget.maxResidentBytes;
      if (!bridgeFitsDetail || !overlapFits) {
        _budgetLimited = true;
        desired =
            bridge.isNotEmpty &&
                _resident({..._displayed.values, ...bridge.values}) <=
                    budget.maxResidentBytes
            ? bridge
            : Map.of(_displayed);
      }
      if (desired.isEmpty && _selected.isNotEmpty && _displayed.isNotEmpty) {
        desired = Map.of(_displayed);
      }
    }
    _updateTransition(desired);
  }

  bool _holdsVisible(String id) =>
      (fadeDuration > Duration.zero && _visible.containsKey(id)) ||
      _displayed.containsKey(id) ||
      _submitted.containsKey(id);

  void _cover(Group group, FragmentCoverage coverage) {
    void visit(Object3D object) {
      if (object is Mesh) object.fragmentCoverage = coverage;
      for (final child in object.children) {
        visit(child);
      }
    }

    visit(group);
  }

  void _finishTransition() {
    final transition = _transition;
    if (transition == null) return;
    for (final group in {...transition.from, ...transition.to}.values) {
      _cover(group, const FragmentCoverage.full());
    }
    _visible = transition.to;
    _transition = null;
  }

  void _updateTransition(Map<String, Group> desired) {
    var transition = _transition;
    if (transition != null) {
      if (desired.isEmpty ||
          _visible.keys.any((id) => !_cache.containsKey(id))) {
        _finishTransition();
        _visible = desired;
        return;
      }
      if (_elapsed - transition.started >= fadeDuration) {
        _finishTransition();
        transition = null;
      }
    }
    if (transition == null) {
      final unchanged =
          desired.length == _visible.length &&
          desired.entries.every((e) => identical(_visible[e.key], e.value));
      if (unchanged) return;
      final union = {..._visible, ...desired};
      bool related(String a, String b) =>
          a.startsWith('$b/') || b.startsWith('$a/');
      final outgoing = _visible.keys.where((id) => !desired.containsKey(id));
      final incoming = desired.keys.where((id) => !_visible.containsKey(id));
      final refinement =
          outgoing.every((a) => desired.keys.any((b) => related(a, b))) &&
          incoming.every((a) => _visible.keys.any((b) => related(a, b)));
      final canFade =
          fadeDuration > Duration.zero &&
          _visible.isNotEmpty &&
          desired.isNotEmpty &&
          refinement &&
          union.length <= budget.maxSelectedTiles &&
          union.keys.every(_cache.containsKey) &&
          union.keys.fold<int>(
                0,
                (n, id) => n + _cache[id]!.content.residentBytes,
              ) <=
              budget.maxResidentBytes &&
          _cachedBytes + _reservedBytes <= budget.maxDecodedBytes;
      if (!canFade) {
        for (final group in _visible.values) {
          _cover(group, const FragmentCoverage.full());
        }
        _visible = desired;
        return;
      }
      transition = _TileTransition(_visible, desired, _elapsed);
      _transition = transition;
    }
    final progress =
        ((_elapsed - transition.started).inMicroseconds /
                fadeDuration.inMicroseconds)
            .clamp(0.0, 1.0);
    _visible = {...transition.from, ...transition.to};
    final outgoing = FragmentCoverage(lower: progress),
        incoming = FragmentCoverage(upper: progress);
    for (final entry in _visible.entries) {
      final before = transition.from.containsKey(entry.key),
          after = transition.to.containsKey(entry.key);
      _cover(
        entry.value,
        before && after
            ? const FragmentCoverage.full()
            : before
            ? outgoing
            : incoming,
      );
    }
  }

  void _evict(String id) {
    if (_holdsVisible(id)) return;
    _prefetched.remove(id);
    final entry = _cache.remove(id);
    if (entry == null) return;
    _selectionDirty = true;
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
              !_prefetch.containsKey(entry.key) &&
              !_holdsVisible(entry.key) &&
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
    _finishTransition();
    _watch.stop();
    for (final request in _active) {
      request.cancelled = true;
      request.task.cancel();
    }
    final waits = [
      for (final entry in [..._cache.values, ..._retired]) entry.scope.close(),
      for (final request in _active) request.done.future,
    ];
    _cache.clear();
    _retired.clear();
    _visible = {};
    _displayed = {};
    _submitted = {};
    _prefetch = {};
    _prefetched.clear();
    _expiredPrefetch.clear();
    _selected = {};
    _screenErrors.clear();
    _branches = {};
    _failures.clear();
    _attempts.clear();
    return _closing = Future.wait(waits).then((_) {});
  }

  void _checkOpen() {
    if (_disposed) throw StateError('3D Tiles streamer is disposed.');
  }
}

final class _TileTransition {
  final Map<String, Group> from, to;
  final Duration started;
  const _TileTransition(this.from, this.to, this.started);
}

final class _LoadedTile {
  final AssetScope scope;
  final _StreamContent content;
  final TileModelInstance3D? group;
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
  bool cancelled = false, prefetch = false;
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
