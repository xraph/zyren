part of 'asset_scope.dart';

typedef _LoadKey = (Uri, String?, Type, Type, Object);

_LoadKey _loadKey<T extends Object>(AssetRequest<T> request) => (
  request.uri,
  request.version,
  T,
  request.loader.runtimeType,
  request.loader.cacheKey,
);

class _SharedLoadPool {
  final AssetServices services;
  final _jobs = <_LoadKey, Object>{};
  _SharedLoadPool(this.services) {
    services.limits.validate();
  }
  LoadTask<T> load<T extends Object>(
    AssetRequest<T> request,
    AssetScope scope,
  ) {
    final key = _loadKey(request);
    final cached = scope.cache?._get<T>(services, key);
    if (cached != null) {
      cached.retain();
      var released = false;
      void release() {
        if (released) return;
        released = true;
        cached.release();
      }

      final task = _AssetTask<T>(scope, this, request.uri, release);
      scheduleMicrotask(() {
        try {
          task.report(
            LoadProgress(
              stage: LoadStage.prepare,
              completedBytes: cached.bytes,
            ),
          );
          final succeeded = task.deliver(cached.decoded);
          if (!succeeded && task._deliveryFailed) {
            cached.invalidate();
          }
        } finally {
          release();
        }
      });
      return task;
    }
    var job = _jobs[key] as _SharedLoad<T>?;
    if (job == null) {
      job = _SharedLoad<T>(this, key, request);
      _jobs[key] = job;
      scheduleMicrotask(job.start);
    }
    return job.join(scope);
  }

  void forget(_LoadKey key, Object job) {
    if (identical(_jobs[key], job)) _jobs.remove(key);
  }

  void cleanup(void Function()? action) {
    try {
      action?.call();
    } catch (error) {
      // Cleanup must never change the success/cancellation outcome of consumers.
      try {
        services.onCleanupError?.call(error);
      } catch (_) {}
    }
  }
}

class _SharedLoad<T extends Object> {
  final _SharedLoadPool pool;
  final _LoadKey key;
  final AssetRequest<T> request;
  final cancellation = LoadCancellationSource();
  final consumers = <_AssetTask<T>>{};
  LoadProgress? latest;
  _SharedLoad(this.pool, this.key, this.request);
  _AssetTask<T> join(AssetScope scope) {
    late final _AssetTask<T> task;
    task = _AssetTask(scope, pool, request.uri, () {
      consumers.remove(task);
      if (consumers.isEmpty) {
        pool.forget(key, this);
        cancelWork();
      }
    });
    consumers.add(task);
    final progress = latest;
    if (progress != null) scheduleMicrotask(() => task.report(progress));
    return task;
  }

  void report(LoadProgress progress) {
    latest = progress;
    for (final consumer in consumers) {
      consumer.report(progress);
    }
  }

  void cancelWork() {
    final errors = cancellation.cancel();
    if (errors.isNotEmpty) {
      pool.cleanup(() => throw ScopeCleanupException(errors));
    }
  }

  Future<void> start() async {
    DecodedAsset<T>? decoded;
    _DecodedRecipe<T>? recipe;
    try {
      cancellation.throwIfCancelled();
      final context = AssetDecodeContext._(
        pool.services,
        request.uri,
        cancellation,
        report,
      );
      final source = await context._read(request.uri);
      cancellation.throwIfCancelled();
      report(LoadProgress(stage: LoadStage.decode, completedBytes: 0));
      decoded = await request.loader.decode(source, context);
      cancellation.throwIfCancelled();
      if ((decoded.decodedBytes ?? 0) < 0) {
        throw AssetLoadException(
          AssetLoadError.invalidData,
          'Decoded recipe size must be nonnegative.',
        );
      }
      pool.forget(key, this);
      report(
        LoadProgress(
          stage: LoadStage.prepare,
          completedBytes: context.decodedBytes,
        ),
      );
      recipe = _DecodedRecipe(
        decoded,
        pool,
        key,
        decoded.decodedBytes ?? context.decodedBytes,
      );
      for (final task in List.of(consumers)) {
        final cache = task.scope.cache;
        final succeeded = task.deliver(decoded);
        if (task._deliveryFailed) recipe.invalidate();
        if (succeeded && cache != null) {
          cache._put(pool.services, key, recipe, task.cacheGeneration);
        }
      }
    } catch (error, stack) {
      pool.forget(key, this);
      cancelWork();
      final failure = error is LoadCancelled || error is AssetLoadException
          ? error
          : AssetLoadException(
              AssetLoadError.decodeFailed,
              'Could not decode the asset.',
              sourceUri: request.uri,
              cause: error,
            );
      for (final task in List.of(consumers)) {
        task.fail(failure, stack);
      }
    } finally {
      consumers.clear();
      if (recipe != null) {
        recipe.release();
      } else {
        pool.cleanup(decoded?.dispose);
      }
      cancellation.finish();
    }
  }
}

class _AssetTask<T extends Object> implements LoadTask<T> {
  final AssetScope scope;
  final _SharedLoadPool pool;
  final Uri sourceUri;
  final void Function() _onCancel;
  final _result = Completer<T>();
  final _progress = StreamController<LoadProgress>.broadcast();
  bool _settled = false;
  bool _deliveryFailed = false;
  final int cacheGeneration;
  _AssetTask(this.scope, this.pool, this.sourceUri, this._onCancel)
    : cacheGeneration = scope.cache?._generation ?? 0 {
    _result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }
  @override
  Future<T> get result => _result.future;
  @override
  Stream<LoadProgress> get progress => _progress.stream;
  void report(LoadProgress value) {
    if (!_settled) _progress.add(value);
  }

  bool deliver(DecodedAsset<T> decoded) {
    if (_settled) return false;
    try {
      if (scope.isClosed) {
        cancel();
        return false;
      }
      final value = decoded.create();
      // A loader callback may synchronously close the scope or cancel its task.
      if (_settled || scope.isClosed) {
        pool.cleanup(() => decoded.releaseValue(value));
        cancel();
        return false;
      }
      scope._retain(value, () => decoded.releaseValue(value));
      _settled = true;
      _result.complete(value);
      unawaited(_progress.close());
      return true;
    } catch (error, stack) {
      _deliveryFailed = true;
      fail(
        error is AssetLoadException || error is LoadCancelled
            ? error
            : AssetLoadException(
                AssetLoadError.decodeFailed,
                'Could not create a scoped asset result.',
                sourceUri: sourceUri,
                cause: error,
              ),
        stack,
      );
      return false;
    }
  }

  void fail(Object error, StackTrace stack) {
    if (_settled) return;
    _settled = true;
    _result.completeError(error, stack);
    unawaited(_progress.close());
  }

  @override
  void cancel() {
    if (_settled) return;
    fail(LoadCancelled(), StackTrace.current);
    _onCancel();
  }
}
