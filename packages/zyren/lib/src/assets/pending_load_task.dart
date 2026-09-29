import 'dart:async';
import 'load_task.dart';

/// Internal completion gate shared by future typed asset loaders.
class PendingLoadTask<T> implements LoadTask<T> {
  final _result = Completer<T>();
  final _progress = StreamController<LoadProgress>.broadcast();
  final void Function()? onCancel;
  bool _settled = false;
  PendingLoadTask(Future<T> computation, {this.onCancel}) {
    _result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    computation.then(
      (value) {
        if (_settled) return;
        _settled = true;
        _result.complete(value);
        unawaited(_progress.close());
      },
      onError: (Object error, StackTrace stack) {
        if (_settled) return;
        _settled = true;
        _result.completeError(error, stack);
        unawaited(_progress.close());
      },
    );
  }
  @override
  Future<T> get result => _result.future;
  @override
  Stream<LoadProgress> get progress => _progress.stream;
  void report(LoadProgress progress) {
    if (!_settled) _progress.add(progress);
  }

  @override
  void cancel() {
    if (_settled) return;
    _settled = true;
    _result.completeError(LoadCancelled());
    unawaited(_progress.close());
    onCancel?.call();
  }
}
