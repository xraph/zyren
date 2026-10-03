import 'dart:async';
import 'package:zyren/zyren.dart';
import 'resource_key.dart';
import 'policy.dart';
import 'store.dart';
import 'request_pool.dart';

typedef GeoResourceFetcher =
    Future<GeoResource> Function(GeoResourceKey, LoadCancellation);
typedef GeoBoundedResourceFetcher =
    Future<GeoResource> Function(
      GeoResourceKey,
      LoadCancellation,
      int maxBytes,
    );
typedef GeoResourceAuthorization =
    FutureOr<bool> Function(GeoResourceKey key, bool offline);

final class GeoResourceRequest {
  final GeoResourceKey key;
  final GeoReadPolicy policy;
  const GeoResourceRequest({required this.key, required this.policy});
}

/// The resolver owns its request pool. The caller retains ownership of the store.
/// Fetchers must bound transport reads by maxResourceBytes before allocating data.
final class GeoResourceResolver {
  final GeoDataStore store;
  final GeoResourceFetcher fetch;
  final GeoBoundedResourceFetcher? boundedFetch;
  final GeoRequestPool pool;
  final GeoResourceAuthorization? authorize;
  final GeoSourceMetadata? Function(GeoResourceKey)? metadata;
  final DateTime Function() now;
  final int maxResourceBytes;
  final Duration retryDelay;
  final _epochs = <GeoResourceKey, _Epoch>{};
  final _mutations = <GeoResourceKey, Future<void>>{};
  final _operations = <Future<void>>{};
  bool _closed = false;
  Future<void>? _closeFuture;
  int cacheAdmissionFailures = 0;
  GeoResourceResolver({
    required this.store,
    required this.fetch,
    this.boundedFetch,
    GeoRequestPool? pool,
    this.authorize,
    this.metadata,
    DateTime Function()? now,
    this.maxResourceBytes = 16 * 1024 * 1024,
    this.retryDelay = const Duration(milliseconds: 100),
  }) : pool = pool ?? GeoRequestPool(),
       now = now ?? _utcNow {
    if (maxResourceBytes < 1 ||
        maxResourceBytes > this.pool.maxInFlightBytes ||
        retryDelay.isNegative ||
        retryDelay > const Duration(minutes: 1)) {
      throw ArgumentError(
        'Resource reads require a positive byte reservation and bounded retry delay.',
      );
    }
  }
  static DateTime _utcNow() => DateTime.now().toUtc();
  void _check(LoadCancellation cancellation) {
    if (_closed) throw const GeoDataException(GeoDataError.closed);
    if (cancellation.isCancelled) {
      throw const GeoDataException(GeoDataError.cancelled);
    }
  }

  void _current(
    GeoResourceKey key,
    _Epoch epoch,
    LoadCancellation cancellation,
  ) {
    _check(cancellation);
    if (!identical(_epochs[key], epoch)) {
      throw const GeoDataException(GeoDataError.cancelled);
    }
  }

  Future<void> _authorize(GeoResourceKey key, bool offline) async {
    try {
      final allowed =
          await (authorize?.call(key, offline) ??
              (key.authorizationPartition == 'public'));
      if (!allowed) throw const GeoDataException(GeoDataError.denied);
    } catch (error) {
      throw GeoDataException(GeoDataError.denied, cause: error);
    }
    sourceMetadata(key);
  }

  GeoSourceMetadata? sourceMetadata(GeoResourceKey key) {
    GeoSourceMetadata? value;
    try {
      value = metadata?.call(key);
    } catch (error) {
      throw GeoDataException(GeoDataError.denied, cause: error);
    }
    if (value != null &&
        (value.sourceId != key.sourceId ||
            value.sourceVersion != key.sourceVersion)) {
      throw const GeoDataException(GeoDataError.denied);
    }
    return value;
  }

  void _verify(GeoResource value, GeoResourceKey key, int limit) {
    if (value.key != key) throw const GeoDataException(GeoDataError.corrupt);
    if (value.bytes.length > limit) {
      throw const GeoDataException(GeoDataError.budgetExceeded);
    }
    value.verify();
    if (value.fetchedAt.isAfter(now().add(const Duration(minutes: 5)))) {
      throw const GeoDataException(GeoDataError.invalidResponse);
    }
  }

  Future<GeoResource> resolve(
    GeoResourceRequest request, {
    required LoadCancellation cancellation,
  }) => read(request.key, request.policy, cancellation: cancellation);

  Future<GeoResource> read(
    GeoResourceKey key,
    GeoReadPolicy policy, {
    required LoadCancellation cancellation,
    int? maxBytes,
  }) => _track(() async {
    _check(cancellation);
    final limit = maxBytes == null || maxBytes > maxResourceBytes
        ? maxResourceBytes
        : maxBytes;
    if (limit < 1) throw const GeoDataException(GeoDataError.budgetExceeded);
    final epoch = _epochs.putIfAbsent(key, _Epoch.new);
    epoch.readers++;
    final offline = policy.mode == GeoAccessMode.offlineOnly;
    try {
      await _authorize(key, offline);
      _current(key, epoch, cancellation);
      await _mutations[key];
      _current(key, epoch, cancellation);
      GeoResource? cached;
      if (policy.mode != GeoAccessMode.onlineOnly) {
        try {
          cached = store is GeoBoundedDataStore
              ? await (store as GeoBoundedDataStore).readBounded(
                  key,
                  maxBytes: limit,
                )
              : limit == maxResourceBytes
              ? await store.read(key)
              : throw const GeoDataException(GeoDataError.budgetExceeded);
          _current(key, epoch, cancellation);
          if (cached != null) _verify(cached, key, limit);
        } on GeoDataException catch (error) {
          if (error.code != GeoDataError.corrupt || offline) rethrow;
          cached = null;
          await _mutate(key, () => store.remove(key));
          _current(key, epoch, cancellation);
        }
        if (offline) {
          if (cached == null) {
            throw const GeoDataException(GeoDataError.offlineMiss);
          }
          if (!cached.isFreshAt(now(), maxAge: policy.maxAge) &&
              !policy.allowStaleOffline) {
            throw const GeoDataException(GeoDataError.stale);
          }
          await _authorize(key, true);
          _current(key, epoch, cancellation);
          return cached;
        }
        if (policy.mode == GeoAccessMode.cacheFirst &&
            cached != null &&
            cached.isFreshAt(now(), maxAge: policy.maxAge)) {
          await _authorize(key, false);
          _current(key, epoch, cancellation);
          return cached;
        }
      }
      try {
        final result = await pool.run(
          (key, policy, epoch, limit),
          key.sourceId,
          reservationBytes: limit,
          cancellation: cancellation,
          work: (physical) => _fetch(key, policy, epoch, physical, limit),
        );
        await _authorize(key, false);
        _current(key, epoch, cancellation);
        return result;
      } on GeoDataException catch (error) {
        _current(key, epoch, cancellation);
        if (error.code != GeoDataError.transportFailure ||
            cached == null ||
            (!cached.isFreshAt(now(), maxAge: policy.maxAge) &&
                !policy.allowStaleOnTransportFailure)) {
          rethrow;
        }
        await _authorize(key, false);
        _current(key, epoch, cancellation);
        _verify(cached, key, limit);
        return cached;
      }
    } finally {
      epoch.readers--;
      if (epoch.readers == 0 && identical(_epochs[key], epoch)) {
        _epochs.remove(key);
      }
    }
  });

  Future<GeoResource> _fetch(
    GeoResourceKey key,
    GeoReadPolicy policy,
    _Epoch epoch,
    LoadCancellation cancellation,
    int limit,
  ) async {
    for (var attempt = 0; attempt < policy.maxAttempts; attempt++) {
      _current(key, epoch, cancellation);
      await _authorize(key, false);
      _current(key, epoch, cancellation);
      GeoResource value;
      try {
        if (boundedFetch != null) {
          value = await boundedFetch!(key, cancellation, limit);
        } else {
          if (limit < maxResourceBytes) {
            throw const GeoDataException(GeoDataError.budgetExceeded);
          }
          value = await fetch(key, cancellation);
        }
      } on LoadCancelled {
        throw const GeoDataException(GeoDataError.cancelled);
      } on GeoDataException catch (error) {
        _current(key, epoch, cancellation);
        if (error.code != GeoDataError.transportFailure ||
            attempt + 1 == policy.maxAttempts) {
          rethrow;
        }
        await Future<void>.delayed(retryDelay * (1 << attempt));
        continue;
      } catch (error) {
        throw GeoDataException(GeoDataError.invalidResponse, cause: error);
      }
      _current(key, epoch, cancellation);
      _verify(value, key, limit);
      await _authorize(key, false);
      _current(key, epoch, cancellation);
      if (policy.mode != GeoAccessMode.onlineOnly && !value.mayPersist) {
        await _mutate(key, () => store.remove(key));
      }
      if (policy.mode != GeoAccessMode.onlineOnly &&
          value.mayPersist &&
          (sourceMetadata(key)?.mayPersist ?? false)) {
        await _mutate(key, () async {
          _current(key, epoch, cancellation);
          await _authorize(key, false);
          _current(key, epoch, cancellation);
          if (!(sourceMetadata(key)?.mayPersist ?? false)) return;
          if (!await store.write(value)) cacheAdmissionFailures++;
        });
      }
      _current(key, epoch, cancellation);
      return value;
    }
    throw const GeoDataException(GeoDataError.transportFailure);
  }

  /// Fences pending reads immediately and drains accepted writes before removal.
  Future<void> remove(GeoResourceKey key) => _track(() {
    if (_closed) throw const GeoDataException(GeoDataError.closed);
    _epochs.remove(key);
    pool.cancelWhere(
      (job, _) =>
          job is (GeoResourceKey, GeoReadPolicy, _Epoch, int) && job.$1 == key,
    );
    return _mutate(key, () => store.remove(key));
  });

  Future<T> _mutate<T>(GeoResourceKey key, Future<T> Function() operation) {
    final previous = _mutations[key] ?? Future<void>.value();
    final result = previous.then((_) => operation());
    final tail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _mutations[key] = tail;
    unawaited(
      tail.then((_) {
        if (identical(_mutations[key], tail)) _mutations.remove(key);
      }),
    );
    return result;
  }

  Future<T> _track<T>(FutureOr<T> Function() operation) {
    final result = Future<T>.sync(operation);
    final settled = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _operations.add(settled);
    unawaited(settled.then((_) => _operations.remove(settled)));
    return result;
  }

  Future<void> close() {
    _closed = true;
    return _closeFuture ??= _drain();
  }

  Future<void> _drain() async {
    await pool.close();
    while (_operations.isNotEmpty || _mutations.isNotEmpty) {
      await Future.wait([..._operations, ..._mutations.values]);
    }
    _epochs.clear();
  }
}

final class _Epoch {
  int readers = 0;
}
