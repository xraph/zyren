import '../plugins/registration.dart';
import 'load_task.dart';

/// A shared job's cancellation signal. A failed job aborts outstanding work.
/// Cancelling one consumer leaves work alive for the remaining consumers.
abstract interface class LoadCancellation {
  bool get isCancelled;
  void throwIfCancelled();
  Registration onCancel(void Function() callback);
}

class LoadCancellationSource implements LoadCancellation {
  final _callbacks = <Object, void Function()>{};
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
      return Registration(() {});
    }
    final key = Object();
    _callbacks[key] = callback;
    return Registration(() => _callbacks.remove(key));
  }

  List<Object> cancel() {
    if (isCancelled) return const [];
    isCancelled = true;
    final callbacks = List.of(_callbacks.values);
    _callbacks.clear();
    final errors = <Object>[];
    for (final callback in callbacks) {
      try {
        callback();
      } catch (error) {
        errors.add(error);
      }
    }
    return errors;
  }

  void finish() => _callbacks.clear();
}
