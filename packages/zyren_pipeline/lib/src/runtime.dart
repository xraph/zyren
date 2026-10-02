import 'dart:async';

import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';

import 'cache.dart';

/// CPU job state. A loaded template does not establish scene or pixel visibility.
enum PipelineJobState { running, succeeded, failed, cancelled, released }

enum PipelineJobKind { validate, load }

final class PipelineJob {
  final String id, bundleVersion, sourceId;
  final PipelineJobKind kind;
  PipelineJobState _state = PipelineJobState.running;
  LoadProgress? _progress;
  String? _errorCode;
  List<SceneIssue> _issues = const [];
  ModelAsset? _model;
  final AssetScope _scope;
  final LoadTask<ModelAsset> _task;
  final Completer<void> _done = Completer<void>();
  PipelineJob._(
    this.id,
    this.bundleVersion,
    this.sourceId,
    this.kind,
    this._scope,
    this._task,
  );
  PipelineJobState get state => _state;
  LoadProgress? get progress => _progress;
  String? get errorCode => _errorCode;
  List<SceneIssue> get issues => _issues;
  ModelAsset? get model => _model;
  Future<void> get done => _done.future;
}

/// Host-owned cache and bounded job lifetime. All commands are also usable without
/// an agent transport. Host scene attachment and authorization stay outside it.
final class PipelineRuntime {
  final PipelineCache cache;
  final AssetServices services;
  final int maxJobs, maxActiveJobs;
  final _jobs = <String, PipelineJob>{};
  int _revision = 0, _sequence = 0;
  bool _closed = false;
  Future<void>? _closing;
  PipelineRuntime({
    required this.cache,
    this.services = const AssetServices(),
    this.maxJobs = 32,
    this.maxActiveJobs = 4,
  }) {
    RangeError.checkValueInInterval(maxJobs, 1, 256, 'maxJobs');
    RangeError.checkValueInInterval(maxActiveJobs, 1, maxJobs, 'maxActiveJobs');
  }
  int get revision => _revision + cache.revision;
  bool get isClosed => _closed;
  List<PipelineJob> get jobs => List.unmodifiable(_jobs.values);
  PipelineJob? job(String id) => _jobs[id];

  PipelineJob start({
    required String bundleVersion,
    required PipelineJobKind kind,
    String? sourceId,
  }) {
    _checkOpen();
    final bundle = cache.peek(bundleVersion);
    if (bundle == null) throw StateError('Bundle is not cached.');
    final source = bundle.resource(sourceId ?? bundle.entrySourceId);
    if (_jobs.values.where((j) => j.state == PipelineJobState.running).length >=
        maxActiveJobs) {
      throw StateError('Active pipeline job budget exceeded.');
    }
    if (_jobs.length >= maxJobs) {
      final disposable = _jobs.values
          .where((j) => j.state != PipelineJobState.running && j.model == null)
          .firstOrNull;
      if (disposable == null) {
        throw StateError('Retained pipeline job budget exceeded.');
      }
      _jobs.remove(disposable.id);
    }
    cache.get(bundleVersion);
    final scope = bundle.open(services: services);
    final task = scope.load(
      bundle.gltfRequest(sourceId: source.source.sourceId),
    );
    final job = PipelineJob._(
      'job-${++_sequence}',
      bundleVersion,
      source.source.sourceId,
      kind,
      scope,
      task,
    );
    _jobs[job.id] = job;
    _revision++;
    unawaited(_run(job));
    return job;
  }

  Future<void> _run(PipelineJob job) async {
    final progress = job._task.progress.listen(
      (value) => job._progress = value,
    );
    try {
      final model = await job._task.result;
      if (_closed || job.state != PipelineJobState.running) return;
      job._issues = List.unmodifiable(model.issues);
      if (job.kind == PipelineJobKind.load) job._model = model;
      job._state = PipelineJobState.succeeded;
    } on LoadCancelled {
      job._state = PipelineJobState.cancelled;
    } on AssetLoadException catch (error) {
      job._errorCode = error.code.name;
      job._state = PipelineJobState.failed;
    } catch (_) {
      job._errorCode = 'decodeFailed';
      job._state = PipelineJobState.failed;
    } finally {
      await progress.cancel();
      if (job.model == null) {
        try {
          await job._scope.close();
        } catch (_) {
          job._errorCode ??= 'cleanupFailed';
          if (job.state == PipelineJobState.succeeded) {
            job._state = PipelineJobState.failed;
          }
        }
      }
      _revision++;
      job._done.complete();
    }
  }

  bool cancel(String jobId) {
    _checkOpen();
    final job = _jobs[jobId];
    if (job == null || job.state != PipelineJobState.running) return false;
    job._state = PipelineJobState.cancelled;
    job._task.cancel();
    _revision++;
    return true;
  }

  Future<bool> release(String jobId) async {
    _checkOpen();
    final job = _jobs[jobId];
    if (job == null || job.model == null) return false;
    job._model = null;
    job._state = PipelineJobState.released;
    _revision++;
    await job._scope.close();
    return true;
  }

  List<String> invalidateSource(String sourceId) {
    _checkOpen();
    return cache.invalidateSource(sourceId);
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    for (final job in _jobs.values) {
      job._task.cancel();
      job._model = null;
      if (job.state == PipelineJobState.running) {
        job._state = PipelineJobState.cancelled;
      } else if (job.kind == PipelineJobKind.load &&
          job.state == PipelineJobState.succeeded) {
        job._state = PipelineJobState.released;
      }
    }
    _revision++;
    try {
      await Future.wait([
        ..._jobs.values.map((j) => j._scope.close()),
        ..._jobs.values.map((j) => j.done),
      ]);
    } finally {
      _jobs.clear();
    }
  }

  void _checkOpen() {
    if (_closed) throw StateError('Pipeline runtime is closed.');
  }
}
