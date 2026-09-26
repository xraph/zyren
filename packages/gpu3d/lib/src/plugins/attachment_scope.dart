import 'dart:async';
import 'registration.dart';

class ScopeCleanupException implements Exception {
  final List<Object> errors;
  ScopeCleanupException(Iterable<Object> errors)
    : errors = List.unmodifiable(errors);
  @override
  String toString() => 'Scope cleanup failed: ${errors.join('; ')}';
}

/// Owns synchronous registrations in reverse order. Closing rejects late work.
class AttachmentScope {
  final _registrations = <Registration>[];
  bool _closed = false;
  bool get isClosed => _closed;
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
    return keep(Registration(() => unawaited(subscription.cancel())));
  }

  void close() {
    if (_closed) return;
    _closed = true;
    final errors = <Object>[];
    for (final registration in _registrations.reversed) {
      try {
        registration.dispose();
      } catch (error) {
        errors.add(error);
      }
    }
    _registrations.clear();
    if (errors.isNotEmpty) throw ScopeCleanupException(errors);
  }
}
