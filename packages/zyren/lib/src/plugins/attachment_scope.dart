import 'dart:async';
import 'registration.dart';

class ScopeCleanupException implements Exception {
  final List<Object> errors;
  ScopeCleanupException(Iterable<Object> errors)
    : errors = List.unmodifiable(errors);
  @override
  String toString() => 'Scope cleanup failed: ${errors.join('; ')}';
}

/// Stops registrations synchronously in reverse order. Await [whenClosed] for
/// asynchronous cleanup and all collected cleanup failures.
class AttachmentScope {
  final _registrations = <Registration>[];
  final _errors = <Object>[];
  final _settled = Completer<void>();
  int _pending = 0;
  bool _closed = false, _closing = false;
  AttachmentScope() {
    _settled.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }
  bool get isClosed => _closed;
  Future<void> get whenClosed => _settled.future;

  Registration keep(Registration registration) {
    if (_closed) {
      registration.dispose();
      throw StateError('Attachment scope has been closed.');
    }
    _registrations.removeWhere((entry) => entry.isDisposed);
    _registrations.add(registration);
    return registration;
  }

  /// Starts cleanup synchronously on close and tracks its asynchronous result.
  /// Cleanup runs once, including when you dispose the registration yourself.
  Registration onClose(FutureOr<void> Function() cleanup) {
    if (_closed) throw StateError('Attachment scope has been closed.');
    return keep(_cleanupRegistration(cleanup));
  }

  Registration _cleanupRegistration(FutureOr<void> Function() cleanup) =>
      Registration(() {
        _pending++;
        Future<void>.sync(cleanup).then<void>(
          (_) {
            _pending--;
            _finish();
          },
          onError: (Object error, StackTrace _) {
            _errors.add(error);
            _pending--;
            _finish();
          },
        );
      });

  Registration listen<T>(
    Stream<T> events,
    void Function(T) onData, {
    void Function(Object, StackTrace)? onError,
  }) {
    if (_closed) throw StateError('Attachment scope has been closed.');
    final subscription = events.listen(onData, onError: onError);
    // listen may synchronously close the scope. keep still cancels this rejected
    // subscription before reporting that attachment has ended.
    return keep(_cleanupRegistration(subscription.cancel));
  }

  void _finish() {
    if (!_closed || _closing || _pending != 0 || _settled.isCompleted) return;
    if (_errors.isEmpty) {
      _settled.complete();
    } else {
      _settled.completeError(ScopeCleanupException(_errors));
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _closing = true;
    final synchronousErrors = <Object>[];
    for (final registration in _registrations.reversed) {
      try {
        registration.dispose();
      } catch (error) {
        synchronousErrors.add(error);
      }
    }
    _registrations.clear();
    _errors.addAll(synchronousErrors);
    _closing = false;
    _finish();
    if (synchronousErrors.isNotEmpty) {
      throw ScopeCleanupException(synchronousErrors);
    }
  }
}
