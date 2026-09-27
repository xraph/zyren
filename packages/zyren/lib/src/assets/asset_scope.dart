import 'dart:async';
import '../plugins/attachment_scope.dart';
import 'load_task.dart';

/// Owns load cancellation and retained CPU assets. Source decoding is supplied
/// by optional loaders; this scope does not imply a built-in format decoder.
class AssetScope {
  final _pending = <LoadTask<Object?>>{};
  final _assets = Set<Object>.identity();
  bool _closed = false;
  Future<void>? _closing;
  bool get isClosed => _closed;
  LoadTask<T> keep<T>(LoadTask<T> task) {
    if (_closed) {
      task.cancel();
      throw StateError('Asset scope has been closed.');
    }
    _pending.add(task);
    task.result.then<void>(
      (value) {
        _pending.remove(task);
        if (!_closed && value != null) _assets.add(value);
      },
      onError: (Object _, StackTrace _) {
        _pending.remove(task);
      },
    );
    return task;
  }

  void release(Object asset) => _assets.remove(asset);
  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    _closed = true;
    final errors = <Object>[];
    for (final task in List.of(_pending)) {
      try {
        task.cancel();
      } catch (error) {
        errors.add(error);
      }
    }
    _pending.clear();
    _assets.clear();
    return _closing = errors.isEmpty
        ? Future.value()
        : Future.error(ScopeCleanupException(errors));
  }
}
