import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';
import 'package:zyren_game/training.dart';

typedef TrainingScenarioCatalog = Map<String, GameTrainingScenario> Function();

void _environmentMain(Map<String, Object?> config) {
  final parent = config['parent'] as SendPort;
  final receive = ReceivePort();
  final environment = GameTrainingEnvironment(
    runId: config['run'] as String,
    environmentId: config['env'] as String,
    purpose: TrainingSplit.values.byName(config['purpose'] as String),
    scenarios: (config['catalog'] as TrainingScenarioCatalog)(),
  );
  final endpoint = LocalTrainingEndpoint(environment);
  parent.send(receive.sendPort);
  receive.listen((message) async {
    final request = message as Map, id = request['id'] as int;
    try {
      if (request['close'] == true) {
        await endpoint.close();
        parent.send({'id': id, 'closed': true});
        // The parent kills the isolate after acknowledging resource cleanup.
        return;
      }
      final frame = TrainingFrameDecoder()
          .add(request['frame'] as Uint8List)
          .single;
      final response = await endpoint.request(frame);
      parent.send({'id': id, 'frame': response.encode()});
    } catch (error) {
      parent.send({'id': id, 'error': error.toString()});
    }
  });
}

final class _IsolateEndpoint implements TrainingEnvironmentEndpoint {
  final ReceivePort responses = ReceivePort(),
      errors = ReceivePort(),
      exits = ReceivePort();
  final Map<int, Completer<TrainingFrame?>> _pending = {};
  final Completer<SendPort> _ready = Completer<SendPort>();
  Isolate? _isolate;
  bool _closed = false;
  int _id = 0;
  _IsolateEndpoint() {
    responses.listen((message) {
      if (message is SendPort) {
        if (!_ready.isCompleted) _ready.complete(message);
        return;
      }
      final result = message as Map;
      final completer = _pending.remove(result['id']);
      if (completer == null) return;
      if (result['error'] != null) {
        completer.completeError(StateError(result['error'] as String));
      } else if (result['closed'] == true) {
        completer.complete(null);
      } else {
        completer.complete(
          TrainingFrameDecoder().add(result['frame'] as Uint8List).single,
        );
      }
    });
    errors.listen(
      (error) => _fail(StateError('Environment isolate failed: $error')),
    );
    exits.listen((_) {
      if (!_closed) _fail(StateError('Environment isolate exited.'));
    });
  }
  static Future<_IsolateEndpoint> create(
    String run,
    String env,
    TrainingSplit purpose,
    TrainingScenarioCatalog catalog,
  ) async {
    final endpoint = _IsolateEndpoint();
    try {
      await Future.wait<Object?>([
        Isolate.spawn(
          _environmentMain,
          {
            'parent': endpoint.responses.sendPort,
            'run': run,
            'env': env,
            'purpose': purpose.name,
            'catalog': catalog,
          },
          onError: endpoint.errors.sendPort,
          onExit: endpoint.exits.sendPort,
          errorsAreFatal: true,
        ).then((isolate) {
          if (endpoint._closed) {
            isolate.kill(priority: Isolate.immediate);
          } else {
            endpoint._isolate = isolate;
          }
          return null;
        }),
        endpoint._ready.future,
      ]).timeout(const Duration(seconds: 10));
      return endpoint;
    } catch (_) {
      endpoint._destroy();
      rethrow;
    }
  }

  void _fail(Object error) {
    if (!_ready.isCompleted) _ready.completeError(error);
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
    _pending.clear();
  }

  Future<TrainingFrame?> _send(Map<String, Object?> value) async {
    if (_closed) throw StateError('Environment endpoint closed.');
    final port = await _ready.future;
    final id = ++_id;
    final completer = Completer<TrainingFrame?>();
    _pending[id] = completer;
    port.send({...value, 'id': id});
    try {
      return await completer.future.timeout(const Duration(seconds: 10));
    } catch (error) {
      _fail(error);
      _destroy();
      rethrow;
    } finally {
      _pending.remove(id);
    }
  }

  @override
  Future<TrainingFrame> request(TrainingFrame frame) async =>
      (await _send({'frame': frame.encode()}))!;
  @override
  Future<void> close() async {
    if (_closed) return;
    try {
      await _send({'close': true});
    } finally {
      _destroy();
    }
  }

  void _destroy() {
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    responses.close();
    errors.close();
    exits.close();
  }
}

Future<void> runTrainingProtocol(
  TrainingScenarioCatalog catalog, {
  Stream<List<int>>? input,
  Future<void> Function(Uint8List bytes)? onResponse,
  Set<String> capabilities = const {'structured', 'snapshot', 'native-physics'},
}) async {
  final supervisor = GameTrainingSupervisor(
    create: (run, env, purpose) =>
        _IsolateEndpoint.create(run, env, purpose, catalog),
    capabilities: capabilities,
  );
  final decoder = TrainingFrameDecoder();
  final jobs = <Future<void>>{};
  Future<void> output = Future.value();
  try {
    await for (final chunk in input ?? stdin) {
      for (final frame in decoder.add(chunk)) {
        if (jobs.length >= 256) {
          throw StateError('Worker request budget exceeded.');
        }
        late Future<void> job;
        job = supervisor
            .dispatch(frame)
            .then((response) {
              output = output.then((_) async {
                final bytes = response.encode(
                  maxHeader: supervisor.maxHeader,
                  maxMessage: supervisor.maxMessage,
                );
                if (onResponse != null) {
                  await onResponse(bytes);
                } else {
                  stdout.add(bytes);
                  await stdout.flush();
                }
              });
              return output;
            })
            .whenComplete(() => jobs.remove(job));
        jobs.add(job);
        decoder.maxHeader = supervisor.maxHeader;
        decoder.maxMessage = supervisor.maxMessage;
      }
    }
    decoder.finish();
    await Future.wait(jobs.toList());
    await output;
  } catch (error, stack) {
    stderr.writeln('$error\n$stack');
    exitCode = 1;
  } finally {
    await supervisor.close();
  }
}
