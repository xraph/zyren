import 'tensor.dart';

enum MlRunStatus { ok, invalid, unsupported, unavailable, cancelled, failed }

final class MlCancellationToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
}

/// Cancellation and deadlines are checked before and after native execution.
/// A1 executes synchronously and cannot interrupt a native call already running.
final class MlRunOptions {
  const MlRunOptions({this.deadline, this.requestId, this.cancellation});
  final DateTime? deadline;
  final String? requestId;
  final MlCancellationToken? cancellation;

  bool get isCancelled =>
      (cancellation?.isCancelled ?? false) ||
      (deadline != null && !DateTime.now().isBefore(deadline!));
}

final class MlRunResult {
  MlRunResult(
    this.status, {
    MlTensorMap tensors = const {},
    this.message,
    this.requestId,
    this.elapsed = Duration.zero,
  }) : tensors = Map.unmodifiable(tensors);
  final MlRunStatus status;
  final MlTensorMap tensors;
  final String? message;
  final String? requestId;
  final Duration elapsed;
}

final class MlLoadException implements Exception {
  const MlLoadException(this.status, this.message);
  final MlRunStatus status;
  final String message;
  @override
  String toString() => 'MlLoadException(${status.name}): $message';
}
