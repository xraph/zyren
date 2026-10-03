part of '../../export.dart';

typedef GameBuildPublisher =
    Future<void> Function(
      PipelineBundle bundle,
      LoadCancellation cancellation,
      void Function() checkBeforeCommit,
    );

sealed class GameBuildStartResult {
  const GameBuildStartResult();
}

final class StartedBuildResult extends GameBuildStartResult {
  final PipelineBuildJob job;
  final int documentRevision;
  const StartedBuildResult(this.job, this.documentRevision);
}

final class InvalidBuildResult extends GameBuildStartResult {
  final List<String> diagnostics;
  InvalidBuildResult(List<String> diagnostics)
    : diagnostics = List.unmodifiable(diagnostics);
}

final class StaleBuildResult extends GameBuildStartResult {
  const StaleBuildResult();
}

final class DeniedBuildResult extends GameBuildStartResult {
  const DeniedBuildResult();
}

final class UnavailableBuildResult extends GameBuildStartResult {
  const UnavailableBuildResult();
}

final class _BuildSnapshot {
  final int revision;
  final List<StudioDocument> documents;
  final String startup;
  final GameBuildProfile profile;
  final Map<String, PipelineAssetReference> models;
  const _BuildSnapshot(
    this.revision,
    this.documents,
    this.startup,
    this.profile,
    this.models,
  );
}

/// Paths, source pins and grants are supplied by the host, never by tool arguments.
final class GameBuildCommands {
  final GameProjectCompiler compiler;
  final List<StudioDocument> Function() documents;
  final int Function() revision;
  final String Function() startupLevel;
  final GameBuildProfile Function() profile;
  final Map<String, PipelineAssetReference> Function() models;
  final bool Function(String scope) allows;
  final bool Function() isAvailable;
  final GameBuildPublisher publish;
  final String outputLabel;
  final String? Function()? outputLocation;
  final List<String> Function()? hostValidation;
  String get currentOutputLabel => outputLocation?.call() ?? outputLabel;
  final void Function()? onChanged;
  final _requests = <String, StartedBuildResult>{};
  late final PipelineBuildRuntime _runtime;
  _BuildSnapshot? _launch;
  bool _closed = false;
  Future<void>? _closing;
  final _changes = StreamController<void>.broadcast(sync: true);
  Stream<void> get changes => _changes.stream;
  void _changed() {
    if (!_closed) {
      _changes.add(null);
      onChanged?.call();
    }
  }

  int _publicationRevision = -1, _nextRequest = 0;
  GameBuildCommands({
    required this.compiler,
    required this.documents,
    required this.revision,
    required this.startupLevel,
    required this.profile,
    Map<String, PipelineAssetReference> Function()? models,
    required this.allows,
    required this.isAvailable,
    required this.publish,
    required this.outputLabel,
    this.onChanged,
    this.outputLocation,
    this.hostValidation,
  }) : models = models ?? (() => const {}) {
    if (outputLabel.isEmpty || outputLabel.length > 4096) {
      throw ArgumentError('Output label must be bounded.');
    }
    _runtime = PipelineBuildRuntime(
      cache: compiler.cache,
      maxActiveJobs: 1,
      recipes: [
        PipelineBuildRecipe(
          id: 'game.export',
          version: GameProjectCompiler.version,
          run: (token) {
            final snapshot =
                _launch ?? (throw StateError('No guarded build snapshot.'));
            _publicationRevision = snapshot.revision;
            return compiler
                .recipe(
                  id: 'game.export',
                  documents: snapshot.documents,
                  startupLevel: snapshot.startup,
                  profile: snapshot.profile,
                  models: snapshot.models,
                )
                .run(token);
          },
        ),
      ],
      publish: (bundle, token) async {
        void check() {
          token.throwIfCancelled();
          _check(_publicationRevision);
        }

        check();
        await publish(bundle, token, check);
      },
    );
  }
  List<String> get validationDiagnostics {
    final diagnostics = <String>[];
    if (_closed || !isAvailable()) return const ['Build host unavailable.'];
    diagnostics.addAll((hostValidation?.call() ?? const <String>[]).take(16));
    for (final document in documents()) {
      try {
        compiler.extensions.validateDocument(document, requireSupported: true);
        GameDocumentCodec(compiler.registry).expand(document);
      } catch (error) {
        final message = error.toString();
        diagnostics.add(message.substring(0, message.length.clamp(0, 2048)));
        if (diagnostics.length == 16) break;
      }
    }
    return List.unmodifiable(diagnostics);
  }

  bool get isClosed => _closed;
  int get stateRevision => revision() + _runtime.revision;
  List<PipelineBuildJob> get jobs => _runtime.jobs;
  List<PipelineBuildJob> get activeJobs => List.unmodifiable(
    jobs.where((j) => j.state == PipelineBuildState.running),
  );
  void _check(int expected) {
    if (_closed || !isAvailable()) throw StateError('Build host detached.');
    if (!allows('game.build')) throw StateError('Build grant was revoked.');
    if (revision() != expected) {
      throw StateError('Authored revision changed during build.');
    }
  }

  GameBuildStartResult startNewBuild({required int expectedRevision}) =>
      startBuild(
        expectedRevision: expectedRevision,
        requestId: 'host-${++_nextRequest}',
      );

  GameBuildStartResult startBuild({
    required int expectedRevision,
    required String requestId,
  }) {
    if (_closed || !isAvailable()) return const UnavailableBuildResult();
    if (!allows('game.build')) return const DeniedBuildResult();
    if (requestId.isEmpty || requestId.length > 256) {
      throw ArgumentError('Build request ID must be bounded.');
    }
    final prior = _requests[requestId];
    if (prior != null) {
      return prior.documentRevision == expectedRevision
          ? prior
          : const StaleBuildResult();
    }
    if (revision() != expectedRevision) return const StaleBuildResult();
    if (activeJobs.isNotEmpty || _requests.length >= 32) {
      return const UnavailableBuildResult();
    }
    final diagnostics = validationDiagnostics;
    if (diagnostics.isNotEmpty) return InvalidBuildResult(diagnostics);
    final snapshot = _BuildSnapshot(
      expectedRevision,
      List.unmodifiable(documents()),
      startupLevel(),
      profile(),
      Map.unmodifiable(models()),
    );
    _check(expectedRevision);
    _launch = snapshot;
    try {
      final job = _runtime.start('game.export');
      final result = StartedBuildResult(job, expectedRevision);
      _requests[requestId] = result;
      _changed();
      unawaited(job.done.then((_) => _changed()));
      return result;
    } finally {
      _launch = null;
    }
  }

  bool cancel(String jobId) {
    if (_closed || !isAvailable() || !allows('game.build')) return false;
    final changed = _runtime.cancel(jobId);
    if (changed) _changed();
    return changed;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _closed = true;
    await _runtime.close();
    await _changes.close();
  }
}
