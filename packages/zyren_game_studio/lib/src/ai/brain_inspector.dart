part of '../../ai.dart';

final class GameAiWorkspace extends ChangeNotifier {
  bool _disposed = false;
  PolicyGroup? group;
  GameEntityHandle? selectedActor;
  final TrainingRunner runner;
  TrainingRunRequest? trainingRequest;
  ModelImport? importer;
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
  GameAiWorkspace({TrainingRunner? runner})
    : runner = runner ?? TrainingRunner();
  Map<String, Object?>? get diagnostic =>
      selectedActor == null ? null : group?.inspect(selectedActor!);
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
    busy = true;
    error = null;
    _notify();
    try {
      if (models.length >= 64 && !models.containsKey(contract.model.sha256)) {
        throw StateError('Model catalog capacity reached.');
      }
      candidate = await importer!.validate(
        contract,
        evaluation: evaluation,
        cancellation: cancellation,
      );
      models[contract.model.sha256] = candidate!;
    } catch (e) {
      error = '$e';
      rethrow;
    } finally {
      busy = false;
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
    final run = await runner.start(request.copyWith(resume: resume));
    await _runUpdates?.cancel();
    _runUpdates = run.changes.listen((_) => notifyListeners());
    _notify();
  }

  Future<void> close() async {
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
      final diagnostic = workspace.diagnostic;
      if (diagnostic == null) {
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
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                Text('NPC ${workspace.selectedActor!.id}'),
                _tourButton(context, 'studio.ai.perception', 'Perception tour'),
              ],
            ),
            const Text('NPC knowledge, historical observations only'),
            _DiagnosticRows(diagnostic: diagnostic),
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
