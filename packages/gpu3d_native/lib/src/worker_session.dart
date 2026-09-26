import 'dart:async';
import 'dart:isolate';
import 'package:gpu3d/gpu3d.dart';

final class WorkerBootstrap {
  final SendPort messages;
  final int generation;
  const WorkerBootstrap(this.messages, this.generation);
}

final class WorkerReady {
  final int generation;
  final SendPort commands;
  const WorkerReady(this.generation, this.commands);
}

final class WorkerRequest {
  final int id, generation;
  final String operation;
  final List<Object> arguments;
  const WorkerRequest(this.id, this.generation, this.operation, this.arguments);
}

final class WorkerReply {
  final int id, generation;
  final bool success;
  final Object? value;
  const WorkerReply(this.id, this.generation, this.success, this.value);
}

/// One isolate session. IDs never repeat within a generation, and messages from
/// retired generations cannot settle current work.
final class WorkerSession {
  static int _nextGeneration = 0;
  final generation = ++_nextGeneration;
  final _messages = ReceivePort();
  final _ready = Completer<void>();
  final _pending = <int, Completer<Object?>>{};
  Isolate? _isolate;
  SendPort? _commands;
  int _nextRequest = 0;
  bool _closed = false, _closing = false;
  Future<void>? _disposal;
  WorkerSession._() {
    // One port preserves worker reply-before-exit ordering.
    _messages.listen(_receive);
    _ready.future.then<void>((_) {}, onError: (Object _, StackTrace _) {});
  }

  static Future<WorkerSession> start(
    void Function(WorkerBootstrap) entry,
  ) async {
    final session = WorkerSession._();
    try {
      session._isolate = await Isolate.spawn(
        entry,
        WorkerBootstrap(session._messages.sendPort, session.generation),
        onError: session._messages.sendPort,
        onExit: session._messages.sendPort,
        errorsAreFatal: true,
      );
      await session._ready.future.timeout(const Duration(seconds: 30));
      return session;
    } catch (error, stack) {
      session.abort();
      if (error is SceneException) rethrow;
      Error.throwWithStackTrace(
        session._issue(
          SceneIssueCodes.backendUnavailable,
          'The native worker could not start.',
          error,
        ),
        stack,
      );
    }
  }

  SceneException _issue(String code, String message, [Object? cause]) =>
      SceneException(
        SceneIssue(
          code: code,
          message: message,
          operation: _commands == null ? 'create' : 'worker',
          cause: cause,
        ),
      );

  void _receive(dynamic message) {
    if (_closed) return;
    if (message is WorkerReady) {
      if (message.generation != generation || _commands != null) return;
      _commands = message.commands;
      _ready.complete();
    } else if (message is WorkerReply) {
      if (message.generation != generation) return;
      final completion = _pending.remove(message.id);
      if (completion == null) return;
      if (message.success) {
        completion.complete(message.value);
      } else {
        completion.completeError(
          _issue(
            SceneIssueCodes.renderFailed,
            'The native worker rejected a request.',
            message.value,
          ),
        );
      }
    } else {
      _fail(
        _issue(
          _commands == null
              ? SceneIssueCodes.backendUnavailable
              : SceneIssueCodes.deviceLost,
          'The native worker exited unexpectedly.',
          message,
        ),
      );
    }
  }

  Future<Object?> request(String operation, List<Object> arguments) {
    if (_closed || _closing) {
      return Future.error(
        _issue(
          SceneIssueCodes.disposed,
          'The native worker session has closed.',
        ),
      );
    }
    return _send(operation, arguments);
  }

  Future<Object?> _send(String operation, List<Object> arguments) {
    final id = ++_nextRequest;
    final completion = Completer<Object?>();
    _pending[id] = completion;
    _commands!.send(WorkerRequest(id, generation, operation, arguments));
    return completion.future;
  }

  void _fail(SceneException error) {
    if (_closed) return;
    _closed = true;
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final completion in _pending.values) {
      completion.completeError(error);
    }
    _pending.clear();
    _messages.close();
    _isolate?.kill(priority: Isolate.immediate);
  }

  Future<void> close() => _disposal ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    _closing = true;
    try {
      await _send('dispose', []).timeout(const Duration(seconds: 5));
    } finally {
      abort();
    }
  }

  /// Used by the renderer finalizer and isolate-failure tests. The worker's
  /// NativeFinalizer owns the GPU handle if the dispose command cannot run.
  void abort() {
    _fail(
      _issue(SceneIssueCodes.disposed, 'The native worker session has closed.'),
    );
    _isolate?.kill(priority: Isolate.immediate);
  }
}
