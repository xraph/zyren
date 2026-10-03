import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'diagnostics.dart';
import 'manifest.dart';
import 'result.dart';
import 'runtime.dart';
import 'session.dart';
import 'tensor.dart';

/// Injectable scheduling boundary. Production uses [MlWorker].
abstract interface class MlInferenceWorker {
  Future<Duration> load(MlModelManifest model, Uint8List bytes);
  Future<MlRunResult> run(
    String hash,
    MlTensorMap tensors,
    MlRunOptions options,
  );
  Future<void> release(String hash);
  Future<MlWorkerDiagnostics> diagnostics();
  Future<void> close();
}

final class MlWorkerEvent {
  const MlWorkerEvent(this.operation, this.modelHash, this.requestId);
  final String operation;
  final String modelHash;
  final String? requestId;
}

/// A dedicated isolate owns every native session. Its command loop is serial.
final class MlWorker implements MlInferenceWorker {
  MlWorker({this.maxPendingOperations = 16}) {
    if (maxPendingOperations <= 0 || maxPendingOperations > 128) {
      throw ArgumentError('Worker pending operation limit must be 1..128.');
    }
  }
  final int maxPendingOperations;
  final _pending = <int, Completer<Map<String, Object?>>>{};
  final _events = StreamController<MlWorkerEvent>.broadcast(sync: true);
  final _startup = Completer<void>();
  ReceivePort? _messages;
  SendPort? _commands;
  Future<void>? _starting;
  Future<void>? _closing;
  var _nextId = 0;
  var _closed = false;
  var _reservedOperations = 0;
  var _runBytes = 0;
  MlWorkerDiagnostics? _lastDiagnostics;
  Stream<MlWorkerEvent> get events => _events.stream;

  Future<void> _start() => _starting ??= _spawn();
  Future<void> _spawn() async {
    _messages = ReceivePort();
    _messages!.listen((message) {
      if (message == null) {
        _fail('Inference worker exited.');
        return;
      }
      if (message is! Map<String, Object?>) {
        _fail(message.toString());
        return;
      }
      final data = message;
      if (data['ready'] is SendPort) {
        _commands = data['ready'] as SendPort;
        _startup.complete();
      } else if (data['event'] == 'run') {
        _events.add(
          MlWorkerEvent(
            'run',
            data['hash'] as String,
            data['requestId'] as String?,
          ),
        );
      } else if (data['id'] is int) {
        _pending.remove(data['id'])?.complete(data);
      } else {
        _fail('Inference worker failed: $message');
      }
    });
    try {
      await Isolate.spawn(
        _serve,
        _messages!.sendPort,
        onExit: _messages!.sendPort,
        onError: _messages!.sendPort,
        errorsAreFatal: true,
      );
      await _startup.future;
    } catch (e) {
      _fail(e.toString());
      rethrow;
    }
  }

  void _fail(String message) {
    _lastDiagnostics = MlWorkerDiagnostics(
      residentModels: null,
      liveSessions: null,
      liveResults: null,
      completedRuns: null,
      failureReason: message,
    );
    if (!_startup.isCompleted) _startup.completeError(StateError(message));
    for (final pending in _pending.values) {
      pending.completeError(
        const MlLoadException(
          MlRunStatus.unavailable,
          'Inference worker is unavailable.',
        ),
      );
    }
    _pending.clear();
    _closed = true;
    _messages?.close();
    unawaited(_events.close());
  }

  Future<Map<String, Object?>> _call(
    String operation,
    Map<String, Object?> data, {
    bool allowClosing = false,
  }) async {
    if (_closed || (_closing != null && !allowClosing)) {
      throw const MlLoadException(
        MlRunStatus.unavailable,
        'Inference worker is closed.',
      );
    }
    if (_reservedOperations >= maxPendingOperations && !allowClosing) {
      throw const MlLoadException(
        MlRunStatus.unavailable,
        'Worker command capacity exceeded.',
      );
    }
    _reservedOperations++;
    try {
      await _start();
      if (_closed) {
        throw const MlLoadException(
          MlRunStatus.unavailable,
          'Inference worker is unavailable.',
        );
      }
      final id = _nextId++;
      final completion = Completer<Map<String, Object?>>();
      _pending[id] = completion;
      _commands!.send({'id': id, 'operation': operation, ...data});
      final result = await completion.future;
      if (result['error'] != null) {
        throw MlLoadException(
          MlRunStatus.values.byName(result['status'] as String),
          result['error'] as String,
        );
      }
      return result;
    } finally {
      _reservedOperations--;
    }
  }

  @override
  Future<Duration> load(MlModelManifest model, Uint8List bytes) async {
    if (bytes.isEmpty || bytes.length > model.maxModelBytes) {
      throw const MlLoadException(
        MlRunStatus.invalid,
        'Worker model payload exceeds manifest bounds.',
      );
    }
    final result = await _call('load', {
      'manifest': model.encode(),
      'bytes': TransferableTypedData.fromList([bytes]),
    });
    return Duration(microseconds: result['elapsed'] as int);
  }

  @override
  Future<MlRunResult> run(
    String hash,
    MlTensorMap tensors,
    MlRunOptions options,
  ) async {
    if (options.isCancelled) {
      return MlRunResult(MlRunStatus.cancelled, requestId: options.requestId);
    }
    final byteLength = tensors.values.fold<int>(0, (n, t) => n + t.byteLength);
    if (tensors.isEmpty ||
        tensors.length > 64 ||
        byteLength > mlMaxTensorBytes - _runBytes) {
      return MlRunResult(
        MlRunStatus.unavailable,
        message: 'Worker tensor transfer capacity exceeded.',
        requestId: options.requestId,
      );
    }
    _runBytes += byteLength;
    try {
      final result = await _call('run', {
        'hash': hash,
        'tensors': _pack(tensors),
        'requestId': options.requestId,
        'deadline': options.deadline?.microsecondsSinceEpoch,
      });
      if (options.isCancelled) {
        return MlRunResult(
          MlRunStatus.cancelled,
          requestId: options.requestId,
          elapsed: Duration(microseconds: result['elapsed'] as int),
        );
      }
      return MlRunResult(
        MlRunStatus.values.byName(result['status'] as String),
        requestId: options.requestId,
        message: result['message'] as String?,
        tensors: _unpack(result['tensors'] as Map<String, Object?>),
        elapsed: Duration(microseconds: result['elapsed'] as int),
      );
    } finally {
      _runBytes -= byteLength;
    }
  }

  @override
  Future<void> release(String hash) async {
    await _call('release', {'hash': hash});
  }

  @override
  Future<MlWorkerDiagnostics> diagnostics() async {
    if (_closed) {
      return _lastDiagnostics ??
          const MlWorkerDiagnostics(
            residentModels: 0,
            liveSessions: 0,
            liveResults: 0,
          );
    }
    final data = await _call('diagnostics', {});
    return _lastDiagnostics = _diagnostic(data);
  }

  @override
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    if (_closed) return;
    if (_starting == null) {
      _closed = true;
      await _events.close();
      return;
    }
    try {
      final data = await _call('close', {}, allowClosing: true);
      _lastDiagnostics = _diagnostic(data);
    } finally {
      _closed = true;
      _messages?.close();
      await _events.close();
    }
  }
}

MlWorkerDiagnostics _diagnostic(Map<String, Object?> data) =>
    MlWorkerDiagnostics(
      residentModels: data['residentModels'] as int,
      liveSessions: data['liveSessions'] as int,
      liveResults: data['liveResults'] as int,
      completedRuns: data['completedRuns'] as int,
      ownerIsolateId: data['ownerIsolateId'] as String,
    );

Map<String, Object?> _pack(MlTensorMap tensors) => tensors.map(
  (name, tensor) => MapEntry(name, {
    'dtype': tensor.dtype.name,
    'shape': tensor.shape,
    'bytes': TransferableTypedData.fromList([tensor.bytes]),
  }),
);
MlTensorMap _unpack(Map<String, Object?> tensors) => tensors.map((name, item) {
  final tensor = item as Map<String, Object?>;
  return MapEntry(
    name,
    MlTensor(
      MlDtype.values.byName(tensor['dtype'] as String),
      (tensor['shape'] as List).cast<int>(),
      (tensor['bytes'] as TransferableTypedData).materialize().asUint8List(),
    ),
  );
});

Future<void> _serve(SendPort parent) async {
  final commands = ReceivePort();
  final sessions = <String, MlSession>{};
  const runtime = MlRuntime();
  Map<String, Object?> diagnostic() {
    final native = runtime.diagnostics;
    return {
      'residentModels': sessions.length,
      'liveSessions': native.liveSessions,
      'liveResults': native.liveResults,
      'completedRuns': native.completedRuns,
      'ownerIsolateId': Isolate.current.hashCode.toString(),
    };
  }

  parent.send({'ready': commands.sendPort});
  try {
    await for (final message in commands) {
      final data = message as Map<String, Object?>;
      final reply = <String, Object?>{'id': data['id']};
      try {
        switch (data['operation']) {
          case 'load':
            final model = MlModelManifest.decode(data['manifest'] as String);
            if (sessions.containsKey(model.sha256)) {
              throw StateError('Duplicate worker model pin.');
            }
            final bytes = (data['bytes'] as TransferableTypedData)
                .materialize()
                .asUint8List();
            final watch = Stopwatch()..start();
            sessions[model.sha256] = await runtime.load(
              model,
              (_) async => bytes,
            );
            reply['elapsed'] = watch.elapsedMicroseconds;
          case 'run':
            final hash = data['hash'] as String;
            final session = sessions[hash];
            if (session == null) {
              throw const MlLoadException(
                MlRunStatus.unavailable,
                'Model is not resident in worker.',
              );
            }
            final tensors = _unpack(data['tensors'] as Map<String, Object?>);
            parent.send({
              'event': 'run',
              'hash': hash,
              'requestId': data['requestId'],
            });
            final deadline = data['deadline'] as int?;
            final result = await session.run(
              tensors,
              MlRunOptions(
                requestId: data['requestId'] as String?,
                deadline: deadline == null
                    ? null
                    : DateTime.fromMicrosecondsSinceEpoch(deadline),
              ),
            );
            reply.addAll({
              'status': result.status.name,
              'message': result.message,
              'tensors': _pack(result.tensors),
              'elapsed': result.elapsed.inMicroseconds,
            });
          case 'release':
            await sessions.remove(data['hash'])?.close();
          case 'diagnostics':
            reply.addAll(diagnostic());
          case 'close':
            for (final session in sessions.values) {
              await session.close();
            }
            sessions.clear();
            reply.addAll(diagnostic());
            parent.send(reply);
            commands.close();
            return;
          default:
            throw StateError('Unknown inference worker operation.');
        }
      } catch (e) {
        reply.addAll({
          'error': e.toString(),
          'status': e is MlLoadException
              ? e.status.name
              : MlRunStatus.failed.name,
        });
      }
      parent.send(reply);
    }
  } finally {
    for (final session in sessions.values) {
      await session.close();
    }
    commands.close();
  }
}
