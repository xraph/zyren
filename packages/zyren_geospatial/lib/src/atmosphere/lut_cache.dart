import 'dart:async';
import 'package:zyren/zyren.dart';
import 'parameters.dart';
import 'quality.dart';
import 'luts.dart';

/// A lease prevents eviction. Close it after removing effects using its tables.
final class AtmosphereLutLease {
  final AtmosphereLuts luts;
  final _Entry _entry;
  bool _closed = false;
  AtmosphereLutLease._(this.luts, this._entry);
  bool get isClosed => _closed || luts.isClosed;
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _entry.references--;
  }
}

class _Request {
  final bool Function()? cancelled;
  _Request(this.cancelled);
  bool get isCancelled => cancelled?.call() ?? false;
}

class _Entry {
  final GpuScope scope;
  final completer = Completer<AtmosphereLuts>();
  final requests = <_Request>{};
  int references = 0;
  bool started = false;
  _Entry(this.scope) {
    completer.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }
}

/// Bounded LRU of immutable tables on one GPU device generation. Parameters,
/// algorithm version, precision and profile form each key. A new device requires
/// a new owner scope and cache. Failed candidates never replace a published set.
final class AtmosphereLutCache {
  final GpuScope _scope;
  final int maxEntries;
  final _entries = <String, _Entry>{};
  Future<void> _admitting = Future.value();
  Future<void>? _closing;
  bool _closed = false;
  AtmosphereLutCache._(this._scope, this.maxEntries);
  factory AtmosphereLutCache(GpuScope owner, {int maxEntries = 2}) {
    if (maxEntries < 1 || maxEntries > 4) {
      throw ArgumentError.value(maxEntries, 'maxEntries');
    }
    return AtmosphereLutCache._(
      owner.createChild(label: 'atmosphere LUT cache'),
      maxEntries,
    );
  }
  int get entryCount => _entries.length;
  bool get isClosed => _closed || _scope.isClosed;
  void _check() {
    if (isClosed) throw StateError('Atmosphere LUT cache has closed.');
  }

  Future<AtmosphereLutLease> acquire({
    required AtmosphereParameters parameters,
    AtmosphereQuality quality = AtmosphereQuality.balanced,
    bool Function()? isCancelled,
  }) async {
    _check();
    if (isCancelled?.call() ?? false) {
      throw StateError('Atmosphere request cancelled.');
    }
    final key = '${quality.key}/${parameters.key}';
    final request = _Request(isCancelled);
    final ready = Completer<_Entry>();
    // Serialize admission only. Shared generation and independent consumers can
    // proceed together without racing the bounded-entry check.
    _admitting = _admitting.then((_) async {
      try {
        _check();
        var entry = _entries.remove(key);
        if (entry == null) {
          if (_entries.length >= maxEntries) {
            final idle = _entries.entries
                .where(
                  (e) =>
                      e.value.references == 0 && e.value.completer.isCompleted,
                )
                .firstOrNull;
            if (idle == null) {
              throw StateError('All atmosphere cache entries are in use.');
            }
            _entries.remove(idle.key);
            await idle.value.scope.close();
            _check();
          }
          entry = _Entry(_scope.createChild(label: 'atmosphere $key'));
        }
        _entries[key] = entry;
        entry.references++;
        entry.requests.add(request);
        ready.complete(entry);
      } catch (error, stack) {
        ready.completeError(error, stack);
      }
    });
    final entry = await ready.future;
    if (!entry.started) {
      entry.started = true;
      unawaited(_build(key, entry, parameters, quality));
    }
    try {
      final luts = await entry.completer.future;
      _check();
      if (request.isCancelled) {
        throw StateError('Atmosphere request cancelled.');
      }
      return AtmosphereLutLease._(luts, entry);
    } catch (_) {
      entry.references--;
      rethrow;
    } finally {
      entry.requests.remove(request);
    }
  }

  Future<void> _build(
    String key,
    _Entry entry,
    AtmosphereParameters parameters,
    AtmosphereQuality quality,
  ) async {
    GpuScope? workspace;
    try {
      workspace = entry.scope.createChild(
        label: 'atmosphere precompute workspace',
      );
      final luts = await AtmosphereLuts.generate(
        resources: entry.scope.resources,
        workspace: workspace.resources,
        shaders: workspace.shaders,
        graphs: workspace.graphs,
        parameters: parameters,
        quality: quality,
        isCancelled: () =>
            isClosed || entry.requests.every((r) => r.isCancelled),
      );
      await workspace.close();
      _check();
      entry.completer.complete(luts);
    } catch (error, stack) {
      if (identical(_entries[key], entry)) _entries.remove(key);
      Object failure = error;
      try {
        await entry.scope.close();
      } catch (cleanup) {
        failure = ScopeCleanupException([error, cleanup]);
      }
      entry.completer.completeError(failure, stack);
    }
  }

  Future<void> close() {
    _closed = true;
    return _closing ??= _close();
  }

  Future<void> _close() async {
    await _admitting;
    final pending = [
      for (final e in _entries.values)
        if (e.started)
          e.completer.future.then<void>(
            (_) {},
            onError: (Object _, StackTrace _) {},
          ),
    ];
    try {
      await Future.wait([...pending, _scope.close()]);
    } finally {
      _entries.clear();
    }
  }
}
