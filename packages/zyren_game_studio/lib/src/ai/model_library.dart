part of '../../model_library.dart';

final class ModelImportCandidate {
  final PolicyContract contract;
  final TrainingEvaluation? evaluation;
  final bool compatible;
  final List<String> issues;
  final String observationHash, actionHash;
  ModelImportCandidate._(
    this.contract,
    this.evaluation,
    this.compatible,
    List<String> issues,
    this.observationHash,
    this.actionHash,
  ) : issues = List.unmodifiable(issues);
  bool get accepted =>
      compatible &&
      evaluation != null &&
      evaluation!.accepted &&
      evaluation!.matches(
        model: contract.model.sha256,
        observation: observationHash,
        action: actionHash,
      );
}

final class ModelImport {
  final MlModelCache cache;
  final ObservationSpec observation;
  final ActionSpec action;
  ModelImport({
    required this.cache,
    required this.observation,
    required this.action,
  });
  Future<ModelImportCandidate> validate(
    PolicyContract contract, {
    TrainingEvaluation? evaluation,
    MlCancellationToken? cancellation,
  }) async {
    final issues = <String>[];
    if (contract.observation.hash != observation.hash) {
      issues.add(
        'Observation field order, units, normalization or cadence differs.',
      );
    }
    if (contract.decoder.spec.hash != action.hash) {
      issues.add('Action branches or controller mapping differs.');
    }
    if (cancellation?.isCancelled ?? false) throw const ModelImportCancelled();
    if (issues.isEmpty) {
      MlModelLease? lease;
      try {
        lease = await cache.acquire(contract.model);
      } finally {
        if (lease != null) cache.release(lease);
      }
      if (cancellation?.isCancelled ?? false) {
        throw const ModelImportCancelled();
      }
    }
    if (evaluation != null &&
        !evaluation.matches(
          model: contract.model.sha256,
          observation: observation.hash,
          action: action.hash,
        )) {
      issues.add('Evaluation belongs to different model or schemas.');
    }
    return ModelImportCandidate._(
      contract,
      evaluation,
      issues.isEmpty,
      issues,
      observation.hash,
      action.hash,
    );
  }
}

final class ModelImportCancelled implements Exception {
  const ModelImportCancelled();
}

/// The host commits through its editor/play command and checks authority again.
final class ModelActivation {
  final int Function() currentRevision;
  final FutureOr<void> Function(PolicyContract contract, int expectedRevision)
  apply;
  ModelActivation({required this.currentRevision, required this.apply});
  Future<void> commit(
    ModelImportCandidate candidate, {
    required int expectedRevision,
  }) async {
    if (!candidate.accepted) {
      throw StateError('Only a compatible evaluated artifact can activate.');
    }
    if (currentRevision() != expectedRevision) {
      throw StateError('Editor revision changed.');
    }
    await apply(candidate.contract, expectedRevision);
  }
}
