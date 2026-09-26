import '../rendering/scene_issue.dart';

enum LoadStage { fetch, decode, prepare }

final class LoadProgress {
  final LoadStage stage;
  final int completedBytes;
  final int? totalBytes;
  LoadProgress({
    required this.stage,
    required this.completedBytes,
    this.totalBytes,
  }) {
    if (completedBytes < 0 ||
        (totalBytes != null &&
            (totalBytes! < 0 || completedBytes > totalBytes!))) {
      throw ArgumentError(
        'Load byte counts must be nonnegative and within the known total.',
      );
    }
  }
}

abstract interface class LoadTask<T> {
  Future<T> get result;
  Stream<LoadProgress> get progress;

  /// Cancellation wins until a successful result has been published.
  void cancel();
}

final class LoadCancelled extends SceneException {
  LoadCancelled()
    : super(
        SceneIssue(
          code: SceneIssueCodes.loadCancelled,
          message: 'The load was cancelled.',
          operation: 'load',
        ),
      );
}
