import 'dart:async';
import 'package:zyren/zyren.dart';
import 'manifest_store.dart';
import 'policy.dart';
import 'region.dart';
import 'resolver.dart';
import 'resource_key.dart';

final class GeoRegionProgress {
  final GeoRegionJobState state;
  final int verifiedResources, requiredResources;
  final GeoDataError? error;
  const GeoRegionProgress(
    this.state,
    this.verifiedResources,
    this.requiredResources,
    this.error,
  );
}

/// One resumable job per region. Store revisions reject competing writers.
final class GeoRegionJob {
  final GeoResourceResolver resolver;
  final GeoManifestStore store;
  final GeoReadPolicy downloadPolicy, offlinePolicy;
  final _events = StreamController<GeoRegionProgress>.broadcast(sync: true);
  final _verified = <GeoResourceKey>{};
  GeoRegionPlan? _plan;
  GeoRegionJobState _state = GeoRegionJobState.planned;
  GeoDataError? _error;
  int? _jobRevision, _regionRevision;
  Future<GeoRegionManifest>? _active;
  LoadCancellationSource? _cancellation;
  bool _closed = false;
  GeoRegionJob({
    required this.resolver,
    required this.store,
    GeoReadPolicy? downloadPolicy,
    GeoReadPolicy? offlinePolicy,
  }) : downloadPolicy =
           downloadPolicy ?? GeoReadPolicy(mode: GeoAccessMode.cacheFirst),
       offlinePolicy =
           offlinePolicy ?? GeoReadPolicy(mode: GeoAccessMode.offlineOnly) {
    if (!identical(resolver.store, store) ||
        this.downloadPolicy.mode == GeoAccessMode.onlineOnly ||
        this.downloadPolicy.mode == GeoAccessMode.offlineOnly ||
        this.offlinePolicy.mode != GeoAccessMode.offlineOnly) {
      throw ArgumentError(
        'Region jobs require a shared persistent store and distinct download/offline policies.',
      );
    }
  }
  GeoRegionPlan? get plan => _plan;
  GeoRegionProgress get progress => GeoRegionProgress(
    _state,
    _verified.length,
    _plan?.resources.length ?? 0,
    _error,
  );
  Stream<GeoRegionProgress> get changes => _events.stream;
  String get _jobId => 'job.${_plan!.region.id}';
  String get _regionId => 'region.${_plan!.region.id}';
  void _transition(GeoRegionJobState state, [GeoDataError? error]) {
    _state = state;
    _error = error;
    if (!_events.isClosed) _events.add(progress);
  }

  void _permissions(GeoResourceKey key) {
    if (!(resolver.sourceMetadata(key)?.mayExportOffline ?? false)) {
      throw const GeoDataException(GeoDataError.denied);
    }
  }

  Future<void> _save() async {
    final value = await store.commitManifest(
      _jobId,
      {
        'schema': 1,
        'plan': _plan!.toJson(),
        'state': _state.name,
        'error': _error?.name,
      },
      _verified.map((k) => k.digest).toSet(),
      expectedRevision: _jobRevision,
    );
    _jobRevision = value.revision;
  }

  Future<GeoRegionManifest> _exclusive(
    Future<GeoRegionManifest> Function(LoadCancellationSource) run,
  ) {
    if (_closed) {
      return Future.error(const GeoDataException(GeoDataError.closed));
    }
    if (_active != null) {
      return Future.error(const GeoDataException(GeoDataError.conflict));
    }
    final done = Completer<GeoRegionManifest>(),
        token = LoadCancellationSource();
    _cancellation = token;
    _active = done.future;
    unawaited(
      Future.sync(() => run(token)).then<void>(
        (value) {
          _active = null;
          _cancellation = null;
          done.complete(value);
        },
        onError: (Object error, StackTrace stack) {
          if (_plan != null && _state != GeoRegionJobState.failed) {
            _transition(
              GeoRegionJobState.failed,
              error is GeoDataException
                  ? error.code
                  : GeoDataError.invalidResponse,
            );
          }
          _active = null;
          _cancellation = null;
          done.completeError(error, stack);
        },
      ),
    );
    done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return done.future;
  }

  Future<GeoRegionManifest> start(GeoRegionPlan plan) =>
      _exclusive((token) async {
        for (final resource in plan.resources) {
          _permissions(resource.key);
        }
        _plan = plan;
        _verified.clear();
        _jobRevision = (await store.readManifest(_jobId))?.revision;
        _regionRevision = (await store.readManifest(_regionId))?.revision;
        _transition(GeoRegionJobState.planned);
        await _save();
        return _download(token);
      });
  Future<GeoRegionManifest> resume() => _exclusive((token) async {
    if (_plan == null) {
      throw StateError('Start or restore a region before resuming.');
    }
    return _download(token);
  });
  Future<GeoRegionManifest> _download(LoadCancellationSource token) async {
    _transition(GeoRegionJobState.downloading);
    await _save();
    final failures = <GeoResourceKey, GeoDataError>{};
    var downloadedBytes = 0;
    try {
      for (final resource in _plan!.resources) {
        token.throwIfCancelled();
        try {
          _permissions(resource.key);
          final value = await resolver.read(
            resource.key,
            downloadPolicy,
            cancellation: token,
          );
          downloadedBytes += value.bytes.length;
          if (downloadedBytes > _plan!.maxBytes) {
            throw const GeoDataException(GeoDataError.budgetExceeded);
          }
          if (!value.mayPersist) {
            throw const GeoDataException(GeoDataError.denied);
          }
          // Pin only bytes independently readable from the persistent store.
          await resolver.read(resource.key, offlinePolicy, cancellation: token);
          _verified.add(resource.key);
          await _save();
          _events.add(progress);
        } on GeoDataException catch (error) {
          if (token.isCancelled || error.code == GeoDataError.cancelled) {
            rethrow;
          }
          failures[resource.key] = error.code;
          if (error.code == GeoDataError.conflict) rethrow;
        }
      }
      token.throwIfCancelled();
      return await _verify(token, downloadFailures: failures);
    } on LoadCancelled {
      return _pause(failures);
    } on GeoDataException catch (error) {
      if (token.isCancelled || error.code == GeoDataError.cancelled) {
        return _pause(failures);
      }
      _transition(GeoRegionJobState.failed, error.code);
      // A revision conflict must not overwrite a newer worker's progress.
      if (error.code != GeoDataError.conflict) await _save();
      rethrow;
    }
  }

  Future<GeoRegionManifest> _pause(
    Map<GeoResourceKey, GeoDataError> failures,
  ) async {
    // Cancellation retains only bytes still authorized for offline export.
    for (final key in _verified.toList()) {
      try {
        _permissions(key);
        await resolver.read(
          key,
          offlinePolicy,
          cancellation: LoadCancellationSource(),
        );
      } on GeoDataException catch (error) {
        _verified.remove(key);
        failures[key] = error.code;
      }
    }
    _transition(GeoRegionJobState.paused);
    await _save();
    return GeoRegionManifest(
      plan: _plan!,
      verificationFinished: false,
      verifiedKeys: _verified,
      failures: failures,
      verifiedAt: resolver.now(),
    );
  }

  Future<void> cancel() async {
    _cancellation?.cancel();
    await _active;
  }

  Future<GeoRegionManifest> verify() => _exclusive(_verify);
  Future<GeoRegionManifest> _verify(
    LoadCancellationSource token, {
    Map<GeoResourceKey, GeoDataError> downloadFailures = const {},
  }) async {
    if (_plan == null) {
      throw StateError('Start or restore a region before verifying.');
    }
    _transition(GeoRegionJobState.verifying);
    final verified = <GeoResourceKey>{},
        failures = <GeoResourceKey, GeoDataError>{};
    var bytes = 0;
    for (final resource in _plan!.resources) {
      try {
        token.throwIfCancelled();
        // Cached bytes cannot certify a refresh that the source rejected.
        final downloadFailure = downloadFailures[resource.key];
        if (downloadFailure != null) {
          throw GeoDataException(downloadFailure);
        }
        _permissions(resource.key);
        final value = await resolver.read(
          resource.key,
          offlinePolicy,
          cancellation: token,
        );
        bytes += value.bytes.length;
        if (bytes > _plan!.maxBytes) {
          throw const GeoDataException(GeoDataError.budgetExceeded);
        }
        verified.add(resource.key);
      } on LoadCancelled {
        return _pause(failures);
      } on GeoDataException catch (error) {
        if (token.isCancelled) return _pause(failures);
        failures[resource.key] = error.code;
      }
    }
    _verified
      ..clear()
      ..addAll(verified);
    final result = GeoRegionManifest(
      plan: _plan!,
      verifiedKeys: verified,
      failures: failures,
      verifiedAt: resolver.now(),
    );
    if (token.isCancelled) return _pause(failures);
    if (result.complete) {
      for (final key in verified) {
        _permissions(key);
      }
      final saved = await store.commitManifest(
        _regionId,
        result.toJson(),
        verified.map((k) => k.digest).toSet(),
        expectedRevision: _regionRevision,
        removeManifests: {_jobId: ?_jobRevision},
      );
      _regionRevision = saved.revision;
      _jobRevision = null;
      _transition(GeoRegionJobState.complete);
    } else {
      _transition(GeoRegionJobState.failed, failures.values.firstOrNull);
      await _save();
    }
    return result;
  }

  static Future<GeoRegionJob?> restore({
    required String id,
    required GeoResourceResolver resolver,
    required GeoManifestStore store,
    GeoReadPolicy? downloadPolicy,
    GeoReadPolicy? offlinePolicy,
  }) async {
    if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$').hasMatch(id)) {
      throw ArgumentError('Invalid region ID.');
    }
    final pending = await store.readManifest('job.$id');
    final complete = await store.readManifest('region.$id');
    final saved = pending ?? complete;
    if (saved == null) return null;
    final job = GeoRegionJob(
      resolver: resolver,
      store: store,
      downloadPolicy: downloadPolicy,
      offlinePolicy: offlinePolicy,
    );
    try {
      final plan = GeoRegionPlan.fromJson(
        saved.document['plan'] as Map<String, Object?>,
      );
      if (plan.region.id != id) {
        throw const GeoDataException(GeoDataError.corrupt);
      }
      job._plan = plan;
      job._jobRevision = pending?.revision;
      job._regionRevision = complete?.revision;
      job._verified.addAll(
        plan.resources
            .map((r) => r.key)
            .where((k) => saved.digests.contains(k.digest)),
      );
      // Restore never downloads. Verification rechecks current authorization and
      // bytes instead of trusting a historical complete flag.
      await job.verify();
      if (pending != null && job._state != GeoRegionJobState.complete) {
        job._transition(GeoRegionJobState.paused);
        await job._save();
      }
      return job;
    } catch (_) {
      await job.close();
      rethrow;
    }
  }

  Future<void> close() async {
    _closed = true;
    try {
      await cancel();
    } finally {
      await _events.close();
    }
  }
}
