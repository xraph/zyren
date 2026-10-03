part of '../../zyren_game.dart';

/// Host leases own resolved bytes and any optional native preparation resources.
abstract interface class GameAssetLease {
  Uint8List get bytes;
  Future<void> close();
}

abstract interface class GameAssetResolver {
  Future<GameAssetLease> load(
    GameAssetReference reference,
    LoadCancellation cancellation,
  );
}

final class GamePreparedLevel {
  final GameSession session;
  final List<GameAssetLease> _assets;
  final GameLevelManager _owner;
  final int _epoch;
  bool _validated = false, _activated = false;
  Future<void>? _closing;
  GamePreparedLevel._(this.session, this._assets, this._owner, this._epoch);
  void validateCapabilities(Set<String> capabilities) {
    if (_closing != null ||
        !capabilities.containsAll(session.project.capabilityRequirements)) {
      throw StateError('Required game capabilities are unavailable.');
    }
    _validated = true;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _owner._prepared.remove(this);
    Object? failure;
    try {
      await session.close();
    } catch (e) {
      failure = e;
    }
    for (final asset in _assets.reversed) {
      try {
        await asset.close();
      } catch (e) {
        failure ??= e;
      }
    }
    _assets.clear();
    if (failure != null) throw StateError('Level cleanup failed: $failure');
  }
}

/// Preparation never replaces the active level. Superseded loads retire candidates.
final class GameLevelManager {
  final CompiledGameProject project;
  final GameAssetResolver resolver;
  final int seed;
  final int maxAssetBytes;
  final List<GameSystem> Function(String levelId) systems;
  final Set<GamePreparedLevel> _prepared = {};
  final Map<Future<GamePreparedLevel>, _GameCancellation> _loads = {};
  GamePreparedLevel? _active;
  int _epoch = 0;
  bool _closed = false;
  Future<void>? _closing;
  Object? cleanupFailure;
  GameLevelManager({
    required this.project,
    required this.resolver,
    required this.seed,
    required this.systems,
    this.maxAssetBytes = 128 * 1024 * 1024,
  }) {
    if (maxAssetBytes < 1 || maxAssetBytes > 0x7fffffff) {
      throw ArgumentError('Invalid asset byte budget.');
    }
  }
  GameSession? get session => _active?.session;
  int get activeAssetCount => _active?._assets.length ?? 0;
  int get preparedCount => _prepared.length;
  Future<GamePreparedLevel> prepare(
    String levelId, {
    LoadCancellation? cancellation,
  }) {
    if (_closed) throw StateError('Level manager is closed.');
    if (_loads.length >= 2) {
      throw StateError('Level preparation budget exceeded.');
    }
    final epoch = ++_epoch;
    _cancelLoads();
    final retiring = _retire(_prepared.toList());
    final token = _GameCancellation();
    final registration = cancellation?.onCancel(token.cancel);
    late final Future<GamePreparedLevel> load;
    load = _prepare(levelId, epoch, token, retiring).whenComplete(() {
      registration?.dispose();
      _loads.remove(load);
    });
    _loads[load] = token;
    return load;
  }

  Future<GamePreparedLevel> _prepare(
    String levelId,
    int epoch,
    LoadCancellation token,
    Future<void> retiring,
  ) async {
    final leases = <GameAssetLease>[];
    var totalBytes = 0;
    GameSession? candidate;
    void check() {
      token.throwIfCancelled();
      if (_closed || epoch != _epoch) throw LoadCancelled();
    }

    try {
      await retiring;
      check();
      if (!project.levels.any((l) => l.id == levelId)) {
        throw StateError('Level is missing.');
      }
      for (final reference in project.assets) {
        check();
        final lease = await resolver.load(reference, token);
        leases.add(lease);
        check();
        final bytes = lease.bytes;
        totalBytes += bytes.length;
        if (bytes.length > GameLimits.maxSourceBytes ||
            totalBytes > maxAssetBytes ||
            sha256.convert(bytes).toString() != reference.digest) {
          throw StateError('Asset hash differs: ${reference.id}.');
        }
      }
      candidate = GameSession(
        project: project,
        seed: seed,
        levelId: levelId,
        systems: systems(levelId),
      );
      candidate._start();
      check();
      final prepared = GamePreparedLevel._(candidate, leases, this, epoch);
      _prepared.add(prepared);
      return prepared;
    } catch (error, stack) {
      try {
        await candidate?.close();
      } catch (e) {
        cleanupFailure = e;
      }
      for (final lease in leases.reversed) {
        try {
          await lease.close();
        } catch (e) {
          cleanupFailure = e;
        }
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  Future<void> activate(GamePreparedLevel candidate) async {
    if (_closed ||
        candidate._owner != this ||
        candidate._epoch != _epoch ||
        candidate._closing != null ||
        candidate._activated ||
        !candidate._validated ||
        !_prepared.contains(candidate)) {
      throw StateError('Level is not a validated owned candidate.');
    }
    final old = _active;
    _active = candidate;
    candidate._activated = true;
    _prepared.remove(candidate);
    try {
      await old?.close();
    } catch (e) {
      cleanupFailure = e;
      rethrow;
    }
    if (_closed || !_activeIdentical(candidate) || candidate.session.isClosed) {
      throw LoadCancelled();
    }
  }

  Future<GameSession> load(
    String levelId, {
    required Set<String> capabilities,
    LoadCancellation? cancellation,
  }) async {
    final candidate = await prepare(levelId, cancellation: cancellation);
    try {
      candidate.validateCapabilities(capabilities);
      await activate(candidate);
      return candidate.session;
    } catch (_) {
      if (!_activeIdentical(candidate)) {
        _prepared.remove(candidate);
        await candidate.close();
      }
      rethrow;
    }
  }

  bool _activeIdentical(GamePreparedLevel candidate) =>
      identical(_active, candidate);
  void _cancelLoads() {
    for (final token in _loads.values.toList()) {
      try {
        token.cancel();
      } catch (error) {
        cleanupFailure = error;
      }
    }
  }

  Future<void> _retire(Iterable<GamePreparedLevel> candidates) async {
    // Start every close before awaiting so none can remain activatable.
    Object? failure;
    await Future.wait([
      for (final candidate in candidates)
        candidate.close().catchError((Object error) {
          failure ??= error;
          cleanupFailure = error;
        }),
    ]);
    if (failure != null) {
      throw StateError('Level manager cleanup failed: $failure');
    }
  }

  Future<void> unload() async {
    _epoch++;
    _cancelLoads();
    final retiring = {..._prepared, ?_active};
    _active = null;
    await _retire(retiring);
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    _epoch++;
    _cancelLoads();
    for (final load in _loads.keys.toList()) {
      try {
        await load;
      } catch (_) {}
    }
    final retiring = {..._prepared, ?_active};
    _active = null;
    await _retire(retiring);
    _prepared.clear();
  }
}

final class _GameCancellation implements LoadCancellation {
  final Set<void Function()> _callbacks = {};
  bool _cancelled = false;
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
    Object? error;
    for (final callback in _callbacks.toList()) {
      try {
        callback();
      } catch (e) {
        error ??= e;
      }
    }
    _callbacks.clear();
    if (error != null) throw StateError('Cancellation callback failed: $error');
  }
}
