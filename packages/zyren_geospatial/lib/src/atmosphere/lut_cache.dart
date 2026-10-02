import 'dart:async';
import 'package:zyren/zyren.dart';
import 'parameters.dart';
import 'quality.dart';
import 'luts.dart';
import 'precomputed_source.dart';

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
  final _entries = <Object, _Entry>{};
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
    PrecomputedAtmosphereSource? source,
    bool Function()? isCancelled,
  }) async {
    _check();
    if (isCancelled?.call() ?? false) {
      throw StateError('Atmosphere request cancelled.');
    }
    if (source != null && source.parameters.key != parameters.key) {
      throw ArgumentError(
        'Atmosphere parameters must match the imported tables.',
      );
    }
    final key = (
      source,
      source == null ? quality.key : 'source-rgba16-v1',
      parameters.key,
    );
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
          entry = _Entry(_scope.createChild(label: 'atmosphere LUT candidate'));
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
      unawaited(_build(key, entry, parameters, quality, source));
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
    Object key,
    _Entry entry,
    AtmosphereParameters parameters,
    AtmosphereQuality quality,
    PrecomputedAtmosphereSource? source,
  ) async {
    GpuScope? workspace;
    try {
      bool stopped() => isClosed || entry.requests.every((r) => r.isCancelled);
      final AtmosphereLuts luts;
      if (source == null) {
        workspace = entry.scope.createChild(
          label: 'atmosphere precompute workspace',
        );
        luts = await AtmosphereLuts.generate(
          resources: entry.scope.resources,
          workspace: workspace.resources,
          shaders: workspace.shaders,
          graphs: workspace.graphs,
          parameters: parameters,
          quality: quality,
          isCancelled: stopped,
        );
        await workspace.close();
      } else {
        final cancellation = _SourceCancellation(stopped);
        try {
          final tables = await source.load(cancellation: cancellation);
          luts = await AtmosphereLuts.fromPrecomputed(
            resources: entry.scope.resources,
            tables: tables,
            isCancelled: stopped,
          );
        } finally {
          cancellation.close();
        }
      }
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

/// Bridges the cache's polling API to resolver cancellation subscriptions.
final class _SourceCancellation implements LoadCancellation {
  final bool Function() stopped;
  final callbacks = <Object, void Function()>{};
  late final Timer timer;
  bool _cancelled = false;
  _SourceCancellation(this.stopped) {
    timer = Timer.periodic(const Duration(milliseconds: 10), (_) => _poll());
  }
  void _poll() {
    if (_cancelled || !stopped()) return;
    _cancelled = true;
    final pending = callbacks.values.toList();
    callbacks.clear();
    for (final callback in pending) {
      try {
        callback();
      } catch (_) {
        /* Cancellation still retires physical work. */
      }
    }
  }

  @override
  bool get isCancelled {
    _poll();
    return _cancelled;
  }

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
    callbacks[key] = callback;
    return Registration(() => callbacks.remove(key));
  }

  void close() {
    timer.cancel();
    callbacks.clear();
  }
}
