import 'dart:async';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';

/// Immutable manifest node. Byte counts are admission ceilings for payloads.
final class SpatialChunk {
  final String id, version;
  final Uri uri;
  final Bounds3 bounds;
  final double geometricError;
  final int decodedBytes, gpuBytes;
  final List<SpatialChunk> children;
  SpatialChunk({
    required this.id,
    required this.uri,
    required this.version,
    required this.bounds,
    required this.geometricError,
    required this.decodedBytes,
    required this.gpuBytes,
    Iterable<SpatialChunk> children = const [],
  }) : children = List.unmodifiable(children) {
    if (id.isEmpty ||
        id.length > 1024 ||
        !uri.hasScheme ||
        version.isEmpty ||
        bounds.isEmpty ||
        !geometricError.isFinite ||
        geometricError < 0 ||
        decodedBytes <= 0 ||
        gpuBytes <= 0) {
      throw ArgumentError(
        'Invalid spatial chunk identity, bounds, error or byte ceiling.',
      );
    }
  }
}

final class SpatialStreamBudget {
  final int maxRequests,
      maxSelectedChunks,
      maxDecodedBytes,
      maxGpuBytes,
      maxCachedBytes;
  final double screenError;
  const SpatialStreamBudget({
    this.maxRequests = 4,
    this.maxSelectedChunks = 128,
    this.maxDecodedBytes = 64 * 1024 * 1024,
    this.maxGpuBytes = 16 * 1024 * 1024,
    this.maxCachedBytes = 16 * 1024 * 1024,
    this.screenError = 2,
  });
  void validate() {
    RangeError.checkValueInInterval(maxRequests, 1, 32);
    RangeError.checkValueInInterval(maxSelectedChunks, 1, 4096);
    for (final n in [maxDecodedBytes, maxGpuBytes, maxCachedBytes]) {
      RangeError.checkValueInInterval(n, 0, 0x7fffffff);
    }
    if (maxDecodedBytes == 0 ||
        maxGpuBytes == 0 ||
        !screenError.isFinite ||
        screenError <= 0) {
      throw ArgumentError(
        'Streaming needs positive data, GPU and screen error budgets.',
      );
    }
  }
}

final class SpatialPayload<T> {
  final T data;
  final int decodedBytes, gpuBytes;
  final void Function()? onDispose;
  bool _disposed = false;
  SpatialPayload(
    this.data, {
    required this.decodedBytes,
    required this.gpuBytes,
    this.onDispose,
  });
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    onDispose?.call();
  }
}

final class SpatialCancellation implements LoadCancellation {
  bool _cancelled = false;
  final _callbacks = <void Function()>[];
  @override
  bool get isCancelled => _cancelled;
  @override
  void throwIfCancelled() {
    if (_cancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (_cancelled) {
      callback();
      return Registration(() {});
    }
    _callbacks.add(callback);
    return Registration(() => _callbacks.remove(callback));
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final cb in List.of(_callbacks)) {
      cb();
    }
    _callbacks.clear();
  }
}

typedef SpatialLoader<T> =
    Future<SpatialPayload<T>> Function(
      SpatialChunk chunk,
      LoadCancellation cancellation,
    );

final class SpatialStreamStats {
  final int selectedChunks,
      visibleChunks,
      activeRequests,
      decodedBytes,
      reservedBytes,
      cachedBytes,
      gpuPayloadBytes;
  final bool budgetLimited;
  const SpatialStreamStats({
    required this.selectedChunks,
    required this.visibleChunks,
    required this.activeRequests,
    required this.decodedBytes,
    required this.reservedBytes,
    required this.cachedBytes,
    required this.gpuPayloadBytes,
    required this.budgetLimited,
  });
  Map<String, Object?> toJson() => {
    'selectedChunks': selectedChunks,
    'visibleChunks': visibleChunks,
    'activeRequests': activeRequests,
    'decodedBytes': decodedBytes,
    'reservedBytes': reservedBytes,
    'cachedBytes': cachedBytes,
    'gpuPayloadBytes': gpuPayloadBytes,
    'physicalGpuResidentBytes': null,
    'budgetLimited': budgetLimited,
  };
}

final class _Request {
  final cancellation = SpatialCancellation();
  late final Future<void> done;
}

/// Camera-driven replacement refinement with resident ancestor fallback.
/// Cancelled work keeps its reservation until it drains. Byte counts describe
/// payload admission, never physical GPU residency or total process memory.
final class SpatialStreamer<T> {
  final SpatialChunk root;
  final SpatialLoader<T> loader;
  final SpatialStreamBudget budget;
  final _nodes = <String, SpatialChunk>{};
  final _cache = <String, SpatialPayload<T>>{};
  final _requests = <String, _Request>{};
  final _failures = <String, String>{};
  final _listeners = <void Function()>[];
  final _wanted = <String>{}, _selected = <String>{};
  Map<String, T> _visible = {};
  bool _closed = false, _limited = false;
  Future<void>? _closing;
  int revision = 0;
  SpatialStreamer({
    required this.root,
    required this.loader,
    this.budget = const SpatialStreamBudget(),
  }) {
    budget.validate();
    void visit(SpatialChunk n, int depth) {
      if (depth > 32 || _nodes.length >= 10000 || _nodes.containsKey(n.id)) {
        throw ArgumentError(
          'Spatial hierarchy must be unique, acyclic and bounded.',
        );
      }
      _nodes[n.id] = n;
      for (final child in n.children) {
        if (!n.bounds.contains(child.bounds.minimum) ||
            !n.bounds.contains(child.bounds.maximum) ||
            child.geometricError > n.geometricError) {
          throw ArgumentError(
            'Children must fit parent bounds and geometric error.',
          );
        }
        visit(child, depth + 1);
      }
    }

    visit(root, 0);
  }
  bool get isClosed => _closed;
  Map<String, T> get visible => Map.unmodifiable(_visible);
  Map<String, String> get failures => Map.unmodifiable(_failures);
  List<String> get selectedIds => List.unmodifiable(_selected);
  bool get isLoading => _requests.isNotEmpty;
  Registration onChanged(void Function() listener) {
    if (_closed) throw StateError('Stream is closed.');
    _listeners.add(listener);
    return Registration(() => _listeners.remove(listener));
  }

  int get _decoded => _cache.values.fold(0, (s, p) => s + p.decodedBytes);
  int get _reserved =>
      _requests.keys.fold(0, (s, id) => s + _nodes[id]!.decodedBytes);
  int get _cached => _cache.entries
      .where((e) => !_wanted.contains(e.key))
      .fold(0, (s, e) => s + e.value.decodedBytes);
  SpatialStreamStats get stats => SpatialStreamStats(
    selectedChunks: _selected.length,
    visibleChunks: _visible.length,
    activeRequests: _requests.length,
    decodedBytes: _decoded,
    reservedBytes: _reserved,
    cachedBytes: _cached,
    gpuPayloadBytes: _visible.keys.fold(0, (s, id) => s + _cache[id]!.gpuBytes),
    budgetLimited: _limited,
  );

  void update(Camera camera, PhysicalSize size, {Mat4? transform}) {
    if (_closed) throw StateError('Stream is closed.');
    final matrix = transform ?? Mat4.identity();
    final m = matrix.storage;
    // Frobenius norm is a conservative bound under shear and nonuniform scale.
    final scale = math.sqrt(
      [0, 1, 2, 4, 5, 6, 8, 9, 10].fold<double>(0, (s, i) => s + m[i] * m[i]),
    );
    final aspect = size.width / size.height,
        frustum = Frustum.fromCamera(camera, size.width / size.height);
    final projected = camera.projectionMatrix(aspect).storage;
    final forward = (camera.target - camera.position).normalized();
    final worldBounds = <String, Bounds3>{};
    Bounds3 bounds(SpatialChunk n) =>
        worldBounds.putIfAbsent(n.id, () => n.bounds.transformed(matrix));
    double error(SpatialChunk n) {
      final b = bounds(n);
      final depth = math.max(
        (camera is PerspectiveCamera
            ? camera.near
            : camera is OrthographicCamera
            ? camera.near
            : 1e-9),
        (b.center - camera.position).dot(forward) - b.size.length / 2,
      );
      return n.geometricError *
          scale *
          projected[5].abs() *
          size.height /
          2 /
          (camera is PerspectiveCamera ? math.max(depth, 1e-9) : 1);
    }

    _limited = false;
    final cut = <SpatialChunk>[];
    if (frustum.intersectsBounds(bounds(root))) {
      if (root.gpuBytes > budget.maxGpuBytes ||
          root.decodedBytes > budget.maxDecodedBytes) {
        _limited = true;
      } else {
        cut.add(root);
      }
    }
    final visited = <String>{};
    while (true) {
      final candidates =
          cut
              .where(
                (n) =>
                    n.children.isNotEmpty &&
                    !visited.contains(n.id) &&
                    error(n) > budget.screenError,
              )
              .toList()
            ..sort((a, b) => error(b).compareTo(error(a)));
      if (candidates.isEmpty) break;
      final n = candidates.first;
      visited.add(n.id);
      final children = n.children
          .where((c) => frustum.intersectsBounds(bounds(c)))
          .toList();
      if (children.isEmpty) continue;
      final bytes =
          cut.fold(0, (s, n) => s + n.gpuBytes) -
          n.gpuBytes +
          children.fold(0, (s, n) => s + n.gpuBytes);
      if (cut.length - 1 + children.length > budget.maxSelectedChunks ||
          bytes > budget.maxGpuBytes) {
        _limited = true;
        continue;
      }
      cut.remove(n);
      cut.addAll(children);
    }
    _selected
      ..clear()
      ..addAll(cut.map((n) => n.id));
    _wanted.clear();
    bool mark(SpatialChunk n) {
      var wanted = _selected.contains(n.id);
      for (final c in n.children) {
        wanted = mark(c) || wanted;
      }
      if (wanted) _wanted.add(n.id);
      return wanted;
    }

    mark(root);
    for (final entry in _requests.entries) {
      if (!_wanted.contains(entry.key)) entry.value.cancellation.cancel();
    }
    _publish();
    _trim();
    _schedule();
  }

  void _notify() {
    revision++;
    for (final cb in List.of(_listeners)) {
      cb();
    }
  }

  List<String>? _coverage(SpatialChunk n) {
    if (!_wanted.contains(n.id)) return const [];
    if (!_selected.contains(n.id)) {
      final children = <String>[];
      var ready = true;
      for (final child in n.children) {
        final result = _coverage(child);
        if (result == null) {
          ready = false;
        } else {
          children.addAll(result);
        }
      }
      if (ready && children.isNotEmpty) return children;
    }
    return _cache.containsKey(n.id) ? [n.id] : null;
  }

  void _publish() {
    var ids = _coverage(root) ?? <String>[];
    // Mixed parent fallbacks can cost more than the ideal cut. Coarsen to a
    // resident root until the replacement fits the visible GPU payload ceiling.
    if (ids.fold(0, (s, id) => s + _cache[id]!.gpuBytes) > budget.maxGpuBytes) {
      ids = _cache.containsKey(root.id) ? [root.id] : [];
      _limited = true;
    }
    final next = {for (final id in ids) id: _cache[id]!.data};
    if (next.keys.join('\x00') != _visible.keys.join('\x00')) {
      _visible = next;
      _notify();
    }
  }

  void _trim({int forBytes = 0}) {
    for (final id in List.of(_cache.keys)) {
      if (_wanted.contains(id) || _visible.containsKey(id)) continue;
      if (_cached <= budget.maxCachedBytes &&
          _decoded + _reserved + forBytes <= budget.maxDecodedBytes) {
        break;
      }
      _cache.remove(id)!.dispose();
    }
  }

  void _schedule() {
    if (_closed) return;
    // Manifest insertion order is parent first, so a first view loads fallback
    // before refinement and does not spend its entire budget on hidden children.
    for (final n in _nodes.values) {
      if (_requests.length >= budget.maxRequests) break;
      if (!_wanted.contains(n.id) ||
          _cache.containsKey(n.id) ||
          _requests.containsKey(n.id) ||
          _failures.containsKey(n.id)) {
        continue;
      }
      _trim(forBytes: n.decodedBytes);
      if (_decoded + _reserved + n.decodedBytes > budget.maxDecodedBytes) {
        _limited = true;
        continue;
      }
      final request = _Request();
      _requests[n.id] = request;
      request.done = _load(n, request);
    }
  }

  Future<void> _load(SpatialChunk node, _Request request) async {
    try {
      final payload = await loader(node, request.cancellation);
      if (_closed ||
          request.cancellation.isCancelled ||
          !_wanted.contains(node.id)) {
        payload.dispose();
        return;
      }
      if (payload.decodedBytes < 0 ||
          payload.gpuBytes < 0 ||
          payload.decodedBytes > node.decodedBytes ||
          payload.gpuBytes > node.gpuBytes) {
        payload.dispose();
        throw StateError('Chunk payload exceeded its manifest reservation.');
      }
      _cache[node.id] = payload;
    } catch (error) {
      if (!_closed && !request.cancellation.isCancelled) {
        _failures[node.id] = error.toString();
      }
    } finally {
      _requests.remove(node.id);
      if (!_closed) {
        _publish();
        _trim();
        _schedule();
        _notify();
      }
    }
  }

  void retryFailed({String? id}) {
    if (_closed) throw StateError('Stream is closed.');
    if (id == null) {
      _failures.clear();
    } else {
      _failures.remove(id);
    }
    _schedule();
    _notify();
  }

  /// Completes only after accepted requests, including obsolete requests, drain.
  Future<void> settle() async {
    while (_requests.isNotEmpty) {
      await Future.wait(_requests.values.map((r) => r.done));
    }
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    for (final r in _requests.values) {
      r.cancellation.cancel();
    }
    await settle();
    for (final payload in _cache.values) {
      payload.dispose();
    }
    _cache.clear();
    _visible = {};
    _selected.clear();
    _wanted.clear();
    _listeners.clear();
  }
}
