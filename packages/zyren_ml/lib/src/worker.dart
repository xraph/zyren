import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'diagnostics.dart';
import 'manifest.dart';
import 'provider.dart';
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
typedef MlWorkerSpawner =
    Future<void> Function(void Function(SendPort), SendPort);

final class MlWorker implements MlInferenceWorker {
  MlWorker({
    int maxPendingOperations = 16,
    MlWorkerSpawner? spawner,
    Map<String, MlProviderSelection> providerSelections = const {},
  }) : this._(maxPendingOperations, spawner, providerSelections, null);

  // Authority can only be minted inside the numerical/partition probe library.
  MlWorker.forProviderProbe(MlProviderProbeAuthority authority)
    : this._(16, null, const {}, authority);

  MlWorker._(
    this.maxPendingOperations,
    MlWorkerSpawner? spawner,
    Map<String, MlProviderSelection> selections,
    this._probeAuthority,
  ) : _spawner = spawner ?? _spawnIsolate,
      _providerSelections = Map.unmodifiable(selections) {
    if (selections.length > 8 ||
        selections.entries.any((e) => e.key != e.value.modelHash)) {
      throw ArgumentError(
        'Provider selections require at most eight exact model pins.',
      );
    }
    if (maxPendingOperations <= 0 || maxPendingOperations > 128) {
      throw ArgumentError('Worker pending operation limit must be 1..128.');
    }
  }
  final MlWorkerSpawner _spawner;
  final Map<String, MlProviderSelection> _providerSelections;
  final MlProviderProbeAuthority? _probeAuthority;
  static Future<void> _spawnIsolate(
    void Function(SendPort) entry,
    SendPort port,
  ) async {
    await Isolate.spawn(
      entry,
      port,
      onExit: port,
      onError: port,
      errorsAreFatal: true,
    );
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
    // Register before spawn, which can fail without ever awaiting readiness.
    unawaited(
      _startup.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
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
      await _spawner(_serve, _messages!.sendPort);
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
    final selection = _providerSelections[model.sha256];
    if (selection != null && !selection.matches(model: model)) {
      throw const MlLoadException(
        MlRunStatus.unsupported,
        'Expired or mismatched provider qualification.',
      );
    }
    final result = await _call('load', {
      'provider': selection?.provider ?? _probeAuthority?.provider ?? 'cpu',
      'profile': _probeAuthority != null,
      'qualifiedShapes': selection?.inputShapes,
      'qualificationDeadline': selection == null
          ? null
          : DateTime.now().add(selection.validFor).microsecondsSinceEpoch,
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
    final selection = _providerSelections[hash];
    if (selection != null && !selection.accepts(tensors)) {
      return MlRunResult(
        MlRunStatus.unsupported,
        message: 'Input shape was not provider-qualified.',
        requestId: options.requestId,
      );
    }
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
    final providerDeadline = selection == null
        ? null
        : DateTime.now().add(selection.validFor);
    final deadline = providerDeadline == null
        ? options.deadline
        : options.deadline == null ||
              providerDeadline.isBefore(options.deadline!)
        ? providerDeadline
        : options.deadline;
    _runBytes += byteLength;
    try {
      final result = await _call('run', {
        'hash': hash,
        'tensors': _pack(tensors),
        'requestId': options.requestId,
        'deadline': deadline?.microsecondsSinceEpoch,
      });
      if (selection != null && !selection.accepts(tensors)) {
        return MlRunResult(
          MlRunStatus.unsupported,
          message: 'Provider qualification expired during native work.',
          requestId: options.requestId,
        );
      }
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

  Future<Map<String, Object?>> finishProviderProbe(String hash) async {
    if (_probeAuthority == null) {
      throw StateError('This worker has no probe authority.');
    }
    return _call('profile', {'hash': hash});
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
  final profiles = <String, Directory>{};
  Future<void> cleanup(String hash) async {
    await sessions.remove(hash)?.close();
    final directory = profiles.remove(hash);
    if (directory != null && await directory.exists()) {
      await directory.delete(recursive: true);
    }
  }

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
            final qualificationDeadline = data['qualificationDeadline'] as int?;
            final providerExpiry = qualificationDeadline == null
                ? null
                : DateTime.fromMicrosecondsSinceEpoch(qualificationDeadline);
            if (providerExpiry != null &&
                !DateTime.now().isBefore(providerExpiry)) {
              throw const MlLoadException(
                MlRunStatus.unsupported,
                'Provider qualification expired in worker queue.',
              );
            }
            Directory? profile;
            if (data['profile'] == true) {
              profile = await Directory.systemTemp.createTemp(
                'zyren_ml_provider_',
              );
              profiles[model.sha256] = profile;
            }
            try {
              sessions[model.sha256] = await loadProviderModel(
                model,
                (_) async => bytes,
                provider: data['provider'] as String,
                profilePrefix: profile == null ? null : '${profile.path}/graph',
                qualificationDeadline: providerExpiry,
                inputQualification: providerExpiry == null
                    ? null
                    : (_) => DateTime.now().isBefore(providerExpiry),
                qualifiedShapes: (data['qualifiedShapes'] as Map?)?.map(
                  (key, value) =>
                      MapEntry(key as String, (value as List).cast<int>()),
                ),
              );
            } catch (_) {
              await cleanup(model.sha256);
              rethrow;
            }
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
          case 'profile':
            final hash = data['hash'] as String;
            final directory = profiles[hash];
            final session = sessions[hash];
            if (directory == null || session == null) {
              throw StateError('No active provider probe.');
            }
            final path = session.finishProviderProfile();
            final file = File(path);
            final resolved = await file.resolveSymbolicLinks();
            final root = await directory.resolveSymbolicLinks();
            if (!resolved.startsWith('$root${Platform.pathSeparator}') ||
                await file.length() > 8 * 1024 * 1024) {
              throw StateError('Provider profile exceeds path or byte bounds.');
            }
            final events = jsonDecode(await file.readAsString());
            if (events is! List || events.length > 65536) {
              throw StateError('Invalid bounded profile.');
            }
            final kernels = <String, Set<String>>{};
            for (final event in events) {
              if (event is! Map || event['cat'] != 'Node') continue;
              final args = event['args'];
              if (args is! Map ||
                  args['provider'] is! String ||
                  args['op_name'] is! String) {
                continue;
              }
              final provider = args['provider'] as String;
              if (provider.length > 128 ||
                  (event['name'] as String).length > 512 ||
                  (args['op_name'] as String).length > 128) {
                throw StateError('Invalid kernel identity.');
              }
              kernels
                  .putIfAbsent(provider, () => <String>{})
                  .add('${event['name']}:${args['op_name']}');
            }
            reply['kernels'] = kernels.map(
              (key, value) => MapEntry(key, value.toList()..sort()),
            );
            reply['actualProvider'] = session.actualProvider;
            await file.delete();
          case 'release':
            await cleanup(data['hash'] as String);
          case 'diagnostics':
            reply.addAll(diagnostic());
          case 'close':
            for (final hash in sessions.keys.toList()) {
              await cleanup(hash);
            }
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
    for (final hash in sessions.keys.toList()) {
      await cleanup(hash);
    }
    commands.close();
  }
}
