/// Cooperative cancellation for bounded numerical work and asynchronous loads.
final class ScientificCancellation {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
  void check() {
    if (_cancelled) throw const ScientificCancelled();
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
