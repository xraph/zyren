/// Cooperative cancellation for bounded numerical work and asynchronous loads.
final class ScientificCancellation {
  final bool Function()? isCancellationRequested;
  ScientificCancellation({this.isCancellationRequested});
  bool _cancelled = false;
  bool get isCancelled =>
      _cancelled || (isCancellationRequested?.call() ?? false);
  void cancel() => _cancelled = true;
  void check() {
    if (isCancelled) throw const ScientificCancelled();
  }
}

final class ScientificCancelled implements Exception {
  const ScientificCancelled();
  @override
  String toString() => 'Scientific work was cancelled.';
}

Future<void> scientificYield(ScientificCancellation? cancellation) async {
  cancellation?.check();
  await Future<void>.delayed(Duration.zero);
  cancellation?.check();
}
