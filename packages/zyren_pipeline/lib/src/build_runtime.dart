import 'dart:async';
import 'package:zyren/zyren.dart';
import 'bundle.dart';
import 'cache.dart';
import 'incremental.dart';

/// Host-registered build recipe. Callers select IDs, never paths or executable
/// names. The callback uses the ordinary incremental/preparation APIs.
final class PipelineBuildRecipe {
  final String id, version;
  final Future<PipelineBuildResult> Function(LoadCancellation cancellation) run;
  PipelineBuildRecipe({
    required this.id,
    required this.version,
    required this.run,
  }) {
    if (id.isEmpty ||
        id.length > 256 ||
        version.isEmpty ||
        version.length > 256) {
      throw ArgumentError('Recipe identity and version must be bounded.');
    }
  }
}

enum PipelineBuildState { running, succeeded, cancelled, failed }

final class PipelineBuildJob {
  final String id, recipeId, recipeVersion;
  final PipelineCancellation _token = PipelineCancellation();
  final Completer<void> _done = Completer<void>();
  PipelineBuildState _state = PipelineBuildState.running;
  PipelineBuildResult? _result;
  String? _errorCode;
  bool _cached = false;
  bool get cached => _cached;
  PipelineBuildJob._(this.id, this.recipeId, this.recipeVersion);
  PipelineBuildState get state => _state;
  PipelineBuildResult? get result => _result;
  String? get errorCode => _errorCode;
  Future<void> get done => _done.future;
}

/// Bounded build lifetime and optional durable publication. A publisher must
/// honor cancellation before its own commit point. Once committed, publication
/// is retained even if cancellation arrives during its acknowledgement.
final class PipelineBuildRuntime {
  final PipelineCache cache;
  final List<PipelineBuildRecipe> recipes;
  final int maxJobs, maxActiveJobs, maxRetainedPayloadBytes;
  final Future<void> Function(
    PipelineBundle bundle,
    LoadCancellation cancellation,
  )?
  publish;
  final _jobs = <PipelineBuildJob>[];
  int _revision = 0, _next = 0, _reserved = 0;
  bool _closed = false;
  Future<void>? _closing;
  PipelineBuildRuntime({
    required this.cache,
    required List<PipelineBuildRecipe> recipes,
    this.publish,
    this.maxJobs = 32,
    this.maxActiveJobs = 2,
    this.maxRetainedPayloadBytes = 256 * 1024 * 1024,
  }) : recipes = List.unmodifiable(recipes) {
    if (maxRetainedPayloadBytes < 1 ||
        maxJobs < 1 ||
        maxJobs > 256 ||
        maxActiveJobs < 1 ||
        maxActiveJobs > maxJobs ||
        recipes.length > 128 ||
        recipes.map((r) => r.id).toSet().length != recipes.length) {
      throw ArgumentError('Invalid recipe or job budget.');
    }
  }
  int get revision => _revision + cache.revision;
  bool get isClosed => _closed;
  List<PipelineBuildJob> get jobs => List.unmodifiable(_jobs);
  PipelineBuildJob? job(String id) =>
      _jobs.where((j) => j.id == id).firstOrNull;
  PipelineBuildJob start(String recipeId) {
    if (_closed ||
        _jobs.length >= maxJobs ||
        _jobs.where((j) => j.state == PipelineBuildState.running).length >=
            maxActiveJobs) {
      throw StateError('Build runtime is closed or full.');
    }
    final recipe = recipes.where((r) => r.id == recipeId).firstOrNull;
    if (recipe == null) throw ArgumentError('Unknown build recipe.');
    final job = PipelineBuildJob._(
      'build-${++_next}',
      recipe.id,
      recipe.version,
    );
    _jobs.add(job);
    _revision++;
    unawaited(_run(job, recipe));
    return job;
  }

  Future<void> _run(PipelineBuildJob job, PipelineBuildRecipe recipe) async {
    var reservation = 0;
    try {
      final result = await recipe.run(job._token);
      job._token.throwIfCancelled();
      final retained = _jobs.fold<int>(
        0,
        (sum, j) => sum + (j.result?.bundle.byteLength ?? 0),
      );
      if (retained + _reserved + result.bundle.byteLength >
          maxRetainedPayloadBytes) {
        throw const FormatException('Retained build output budget exceeded.');
      }
      reservation = result.bundle.byteLength;
      _reserved += reservation;
      if (publish != null) {
        await publish!(result.bundle, job._token);
      } else {
        job._token.throwIfCancelled();
      }
      job._cached = cache.put(result.bundle);
      job._result = result;
      job._state = PipelineBuildState.succeeded;
    } on LoadCancelled {
      job._state = PipelineBuildState.cancelled;
    } catch (error) {
      job._state = PipelineBuildState.failed;
      job._errorCode = error is FormatException
          ? 'invalid-build'
          : 'build-failed';
    } finally {
      _reserved -= reservation;
      _revision++;
      job._done.complete();
    }
  }

  bool cancel(String id) {
    final value = job(id);
    if (value == null ||
        value.state != PipelineBuildState.running ||
        value._token.isCancelled) {
      return false;
    }
    value._token.cancel();
    _revision++;
    return true;
  }

  bool forget(String id) {
    final value = job(id);
    if (value == null || value.state == PipelineBuildState.running) {
      return false;
    }
    _jobs.remove(value);
    _revision++;
    return true;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    for (final job in _jobs) {
      cancel(job.id);
    }
    await Future.wait(_jobs.map((j) => j.done));
    _jobs.clear();
    _revision++;
  }
}
