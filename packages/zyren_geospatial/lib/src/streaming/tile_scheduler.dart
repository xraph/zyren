import 'dart:async';
import 'package:zyren/zyren.dart';
import '../tiling.dart';
import 'tile_source.dart';
import 'tile_selection.dart';

/// Selects quadtree content and retains parents until replacement is complete.
/// Cancellation keeps a request slot occupied until the source future settles.
class TileScheduler<T extends TileContent> {
  TileSource<T> _source;
  TileSource<T> get source => _source;
  final TileBudget budget;
  final double maximumScreenError;
  final void Function()? onChanged;
  final _cache = <TileCoordinate, T>{};
  final _active = <_Request<T>>{};
  final _failures = <TileCoordinate, TileFailure>{};
  final _attempts = <TileCoordinate, int>{};
  TileSelection _selection = TileSelection();
  Map<TileCoordinate, T> _visible = const {};
  Map<TileCoordinate, T> _retained = const {};
  bool _replacementBudgetLimited = false;
  bool _selectionReady = false;
  bool get retainingPreviousSource => _retained.isNotEmpty;
  var _generation = 0;
  bool _disposed = false;
  TileScheduler({
    required TileSource<T> source,
    TileBudget? budget,
    this.maximumScreenError = 8,
    this.onChanged,
  }) : _source = source,
       budget = budget ?? TileBudget() {
    if (!maximumScreenError.isFinite ||
        maximumScreenError <= 0 ||
        source.identity.isEmpty) {
      throw ArgumentError(
        'Screen error must be positive and source identity nonempty.',
      );
    }
  }
  Map<TileCoordinate, T> get visible => _visible;
  Set<TileCoordinate> get selected => Set.unmodifiable(_selection.nodes.keys);
  List<TileFailure> get failures => List.unmodifiable(_failures.values);
  int get _cachedBytes =>
      _cache.values.fold(0, (sum, data) => sum + data.decodedBytes) +
      _retained.values.fold(0, (sum, data) => sum + data.decodedBytes);
  int get _reservedBytes =>
      _active.fold(0, (sum, request) => sum + request.metadata.decodedBytes);
  TileStreamingStats get stats => TileStreamingStats(
    selectedTiles: _selection.nodes.length,
    visibleTiles: _visible.length,
    activeRequests: _active.length,
    cachedBytes: _cachedBytes,
    reservedBytes: _reservedBytes,
    residentBytes: _visible.values.fold(
      0,
      (sum, data) => sum + data.residentBytes,
    ),
    budgetLimited: _selection.budgetLimited || _replacementBudgetLimited,
  );

  void update(Camera camera, ViewportMetrics viewport) {
    _checkOpen();
    if (!viewport.isUsable) return;
    final next = selectTiles(
      _source,
      camera,
      viewport,
      budget,
      maximumScreenError,
      _selection.branches.keys.toSet(),
    );
    _selection = next;
    _selectionReady = true;
    for (final request in _active) {
      if (!next.nodes.containsKey(request.metadata.coordinate)) {
        request.cancel.cancel();
      }
    }
    _failures.removeWhere((key, _) => !next.nodes.containsKey(key));
    _attempts.removeWhere((key, _) => !next.nodes.containsKey(key));
    for (final tile in next.nodes.keys) {
      final data = _cache.remove(tile);
      if (data != null) _cache[tile] = data;
    }
    _refreshVisible();
    _pump();
  }

  void replaceSource(TileSource<T> source, {bool retainVisible = false}) {
    _checkOpen();
    if (source.identity.isEmpty) {
      throw ArgumentError('Source identity must be nonempty.');
    }
    _generation++;
    for (final request in _active) {
      request.cancel.cancel();
    }
    _retained = retainVisible ? _visible : const {};
    _source = source;
    _cache.clear();
    _failures.clear();
    _attempts.clear();
    _selection = TileSelection();
    _selectionReady = false;
    _visible = _retained;
    onChanged?.call();
  }

  /// User-driven retries. Exhausted attempts reset only after deselection or
  /// explicit source replacement, so a failing tile cannot spin a retry loop.
  void retryFailed() {
    _checkOpen();
    _failures.removeWhere(
      (_, failure) => failure.attempts < budget.maxAttempts,
    );
    _pump();
  }

  void _pump() {
    if (_disposed) return;
    _replacementBudgetLimited = false;
    for (final metadata in _selection.nodes.values) {
      if (_active.length >= budget.maxRequests) break;
      final tile = metadata.coordinate;
      if (_cache.containsKey(tile) ||
          _failures.containsKey(tile) ||
          _active.any(
            (r) => r.generation == _generation && r.metadata.coordinate == tile,
          )) {
        continue;
      }
      while (_cachedBytes + _reservedBytes + metadata.decodedBytes >
          budget.maxDecodedBytes) {
        final unused = _cache.keys.where(
          (k) => !_selection.nodes.containsKey(k),
        );
        if (unused.isEmpty) break;
        _cache.remove(unused.first);
      }
      if (_cachedBytes + _reservedBytes + metadata.decodedBytes >
          budget.maxDecodedBytes) {
        _replacementBudgetLimited = true;
        continue;
      }
      final request = _Request<T>(_source, metadata, _generation);
      _active.add(request);
      _attempts[tile] = (_attempts[tile] ?? 0) + 1;
      unawaited(_load(request));
    }
  }

  Future<void> _load(_Request<T> request) async {
    final tile = request.metadata.coordinate;
    try {
      final data = await request.source.load(
        tile,
        TileLoadContext(
          sourceIdentity: request.source.identity,
          cancellation: request.cancel,
          byteBudget: request.metadata.decodedBytes,
        ),
      );
      if (!_accepts(request)) return;
      if (data.decodedBytes < 0 ||
          data.residentBytes < 0 ||
          data.decodedBytes > request.metadata.decodedBytes ||
          data.residentBytes > request.metadata.residentBytes) {
        throw StateError('Tile payload exceeds its declared byte reservation.');
      }
      _cache[tile] = data;
    } catch (error) {
      if (_accepts(request)) {
        _failures[tile] = TileFailure(
          request.source.identity,
          tile,
          error,
          _attempts[tile]!,
        );
      }
    } finally {
      request.cancel.finish();
      _active.remove(request);
      if (!_disposed) {
        _refreshVisible();
        _pump();
        onChanged?.call();
      }
    }
  }

  bool _accepts(_Request<T> request) =>
      !_disposed &&
      !request.cancel.isCancelled &&
      request.generation == _generation &&
      _selection.nodes.containsKey(request.metadata.coordinate);

  void _refreshVisible() {
    if (!_selectionReady && _retained.isNotEmpty) return;
    Map<TileCoordinate, T>? coverage(TileCoordinate tile) {
      final children = _selection.branches[tile];
      if (children != null) {
        final group = <TileCoordinate, T>{};
        var complete = true;
        for (final child in children) {
          final found = coverage(child);
          if (found == null) {
            complete = false;
            break;
          }
          group.addAll(found);
        }
        if (complete) return group;
      }
      final data = _cache[tile];
      return data == null ? null : {tile: data};
    }

    final next = <TileCoordinate, T>{};
    var complete = !_selection.budgetLimited || _selection.roots.isNotEmpty;
    for (final root in _selection.roots) {
      final found = coverage(root);
      if (found == null) {
        complete = false;
      } else {
        next.addAll(found);
      }
    }
    if (_retained.isNotEmpty && !complete) {
      _visible = _retained;
    } else {
      _retained = const {};
      _visible = Map.unmodifiable(next);
    }
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final request in _active) {
      request.cancel.cancel();
    }
    _cache.clear();
    _retained = const {};
    _visible = const {};
    _selection = TileSelection();
    _failures.clear();
    _attempts.clear();
  }

  void _checkOpen() {
    if (_disposed) throw StateError('Tile scheduler is disposed.');
  }
}

final class _Request<T extends TileContent> {
  final TileSource<T> source;
  final TileMetadata metadata;
  final int generation;
  final cancel = _Cancellation();
  _Request(this.source, this.metadata, this.generation);
}

final class _Cancellation implements LoadCancellation {
  final _callbacks = <Object, void Function()>{};
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
      return Registration(() {});
    }
    final key = Object();
    _callbacks[key] = callback;
    return Registration(() => _callbacks.remove(key));
  }

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    final callbacks = List.of(_callbacks.values);
    _callbacks.clear();
    for (final callback in callbacks) {
      try {
        callback();
      } catch (_) {
        /* Other requests must still cancel. */
      }
    }
  }

  void finish() => _callbacks.clear();
}
