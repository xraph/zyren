part of '../../ai.dart';

final class GameAiWorkspace extends ChangeNotifier {
  bool _disposed = false;
  int _importSerial = 0;
  Future<void>? _closing;
  final int maxActors;
  PolicyGroup? group;
  Map<String, Object?>? Function(GameEntityHandle actor)? inspectActor;
  List<GameEntityHandle> Function()? availableActors;
  List<GameEntityHandle> get actors => List.unmodifiable(
    (availableActors?.call() ?? group?.actors ?? const <GameEntityHandle>[])
        .take(maxActors),
  );
  GameEntityHandle? selectedActor;
  final TrainingRunner runner;
  TrainingRunRequest? trainingRequest;
  TrainingToolchain? toolchain;
  String? scenarioTemplatePath;
  ModelImport? importer;
  Future<ModelImportCandidate> Function(
    String path,
    MlCancellationToken cancellation,
  )?
  prepareArtifact;
  ModelActivation? activation;
  ModelImportCandidate? candidate;
  final Map<String, ModelImportCandidate> models = {};
  final Map<GameEntityHandle, SensorProfile> sensors = {};
  final Map<GameEntityHandle, CameraObservation> cameras = {};
  final List<DemonstrationArtifact> demonstrations = [];
  bool permitted = true, busy = false;
  String? error, activeModelHash;
  final GameAiWalkthroughs tours = GameAiWalkthroughs();
  StreamSubscription<void>? _runUpdates;
  GameAiWorkspace({TrainingRunner? runner, this.maxActors = 64})
    : runner = runner ?? TrainingRunner() {
    if (maxActors < 1 || maxActors > 256) {
      throw ArgumentError('Actor inspector budget must be1..256.');
    }
  }
  Map<String, Object?>? get diagnostic => selectedActor == null
      ? null
      : (inspectActor?.call(selectedActor!) ?? group?.inspect(selectedActor!));
  void select(GameEntityHandle? actor) {
    selectedActor = actor;
    error = null;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  void refresh() {
    _notify();
  }

  Future<void> importModel(
    PolicyContract contract, {
    TrainingEvaluation? evaluation,
    MlCancellationToken? cancellation,
  }) async {
    if (!permitted || importer == null) {
      throw StateError('Model import is unavailable or denied.');
    }
    if (_disposed || _closing != null) {
      throw StateError('AI workspace is closed.');
    }
    final serial = ++_importSerial, host = importer!;
    busy = true;
    error = null;
    _notify();
    try {
      if (models.length >= 64 && !models.containsKey(contract.model.sha256)) {
        throw StateError('Model catalog capacity reached.');
      }
      final prepared = await host.validate(
        contract,
        evaluation: evaluation,
        cancellation: cancellation,
      );
      if (_disposed ||
          _closing != null ||
          !permitted ||
          serial != _importSerial ||
          !identical(host, importer)) {
        throw const ModelImportCancelled();
      }
      candidate = prepared;
      models[contract.model.sha256] = prepared;
    } catch (e) {
      error = '$e';
      rethrow;
    } finally {
      if (serial == _importSerial) busy = false;
      _notify();
    }
  }

  Future<void> importLocalArtifact(
    String path,
    MlCancellationToken cancellation,
  ) async {
    final host = prepareArtifact;
    if (!permitted || _disposed || _closing != null || host == null) {
      throw StateError('Artifact import is unavailable or denied.');
    }
    final serial = ++_importSerial;
    busy = true;
    error = null;
    _notify();
    try {
      final prepared = await host(path, cancellation);
      if (_disposed ||
          _closing != null ||
          !permitted ||
          serial != _importSerial ||
          cancellation.isCancelled ||
          !identical(host, prepareArtifact)) {
        throw const ModelImportCancelled();
      }
      final hash = prepared.contract.model.sha256;
      if (models.length >= 64 && !models.containsKey(hash)) {
        throw StateError('Model catalog capacity reached.');
      }
      candidate = prepared;
      models[hash] = prepared;
    } catch (e) {
      error = '$e';
      rethrow;
    } finally {
      if (serial == _importSerial) busy = false;
      _notify();
    }
  }

  Future<void> activate() async {
    if (!permitted || candidate == null || activation == null) {
      throw StateError('Activation is unavailable.');
    }
    final next = candidate!;
    final host = activation!;
    await host.commit(next, expectedRevision: host.currentRevision());
    activeModelHash = next.contract.model.sha256;
    _notify();
  }

  Future<void> start({bool resume = false}) async {
    final request = trainingRequest;
    if (!permitted || request == null) {
      throw StateError('Training is not configured.');
    }
    error = null;
    final run = await runner.start(
      request.copyWith(resume: resume),
      authorize: () => permitted && !_disposed && _closing == null,
    );
    await _runUpdates?.cancel();
    _runUpdates = run.changes.listen((_) => _notify());
    _notify();
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _importSerial++;
    await _runUpdates?.cancel();
    await runner.close();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(
      close().catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'Game AI workspace',
          ),
        );
      }),
    );
    super.dispose();
  }
}

class GameBrainInspector extends StatelessWidget {
  final GameAiWorkspace workspace;
  const GameBrainInspector({super.key, required this.workspace});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: workspace,
    builder: (_, _) {
      if (!workspace.permitted) {
        return const ZeroState(
          title: 'AI access denied',
          message: 'Ask your project owner for AI inspection access.',
        );
      }
      final actorChoices = workspace.actors;
      final diagnostic = workspace.diagnostic;
      if (diagnostic == null && actorChoices.isEmpty) {
        return const ZeroState(
          title: 'Select a policy actor',
          message:
              'Start play and choose a registered NPC to inspect its permitted observations and decisions.',
        );
      }
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (actorChoices.isNotEmpty)
              DropdownButtonFormField<GameEntityHandle>(
                key: ValueKey(workspace.selectedActor),
                initialValue: actorChoices.contains(workspace.selectedActor)
                    ? workspace.selectedActor
                    : null,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'NPC actor',
                  isDense: true,
                ),
                items: [
                  for (final actor in actorChoices)
                    DropdownMenuItem(
                      value: actor,
                      child: Text(
                        '${actor.id} · generation ${actor.generation}',
                      ),
                    ),
                ],
                onChanged: workspace.select,
              ),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Text('NPC ${workspace.selectedActor?.id ?? 'not selected'}'),
                _tourButton(context, 'studio.ai.perception', 'Perception tour'),
              ],
            ),
            const Text('NPC knowledge, historical observations only'),
            if (diagnostic != null)
              _DiagnosticRows(diagnostic: diagnostic)
            else
              const ZeroState(
                title: 'Choose an NPC actor',
                message:
                    'Select a live NPC to view permitted observations, memory and decisions.',
              ),
          ],
        ),
      );
    },
  );
}

class _DiagnosticRows extends StatelessWidget {
  final Map<String, Object?> diagnostic;
  const _DiagnosticRows({required this.diagnostic});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final entry in diagnostic.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: SelectableText('${entry.key}: ${jsonEncode(entry.value)}'),
        ),
    ],
  );
}
