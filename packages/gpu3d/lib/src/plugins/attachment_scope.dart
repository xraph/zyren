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
/// asynchronous stream cancellation and all collected cleanup failures.
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
    _registrations.add(registration);
    return registration;
  }

  Registration listen<T>(
    Stream<T> events,
    void Function(T) onData, {
    void Function(Object, StackTrace)? onError,
  }) {
    if (_closed) throw StateError('Attachment scope has been closed.');
    final subscription = events.listen(onData, onError: onError);
    return keep(
      Registration(() {
        _pending++;
        // Future.sync invokes cancel now, so no later stream event is delivered.
        Future<void>.sync(subscription.cancel).then<void>(
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
      }),
    );
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
