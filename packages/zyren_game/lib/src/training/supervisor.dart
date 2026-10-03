part of '../../training.dart';

/// The host may implement each endpoint in its own isolate with native resources.
abstract interface class TrainingEnvironmentEndpoint {
  Future<TrainingFrame> request(TrainingFrame frame);
  Future<void> close();
}

final class LocalTrainingEndpoint implements TrainingEnvironmentEndpoint {
  final GameTrainingEnvironment environment;
  LocalTrainingEndpoint(this.environment);
  @override
  Future<TrainingFrame> request(TrainingFrame frame) async {
    final header = frame.header;
    GameTrainingResult? result;
    final current = environment.instance;
    if (header['operation'] != 'reset' && current != null) {
      final actors = current.actorHandles.map((e) => e.id).toSet();
      final requested = (header['actor_ids'] as List).cast<String>().toSet();
      final generations = _wireMap(header['actor_generations']);
      if (header['episode_id'] != environment.episodeId ||
          header['tick'] != current.session.tick ||
          actors.length != requested.length ||
          !actors.containsAll(requested) ||
          current.actorHandles.any((e) => generations[e.id] != e.generation)) {
        throw StateError('Request episode, actors or tick differ.');
      }
    }
    switch (header['operation']) {
      case 'reset':
        result = await environment.reset(
          seed: header['seed'] as int,
          scenario: _wireId(header['scenario']),
        );
      case 'step':
        if (header['episode_id'] != environment.episodeId ||
            header['tick'] != environment.instance?.session.tick) {
          throw StateError('Request episode or tick is stale.');
        }
        result = await environment.step({
          for (final actor in header['actor_ids'] as List)
            actor as String: frame.float32(
              'action.$actor',
              shape: [environment.instance!.actionWidth],
            ),
        });
      case 'snapshot':
        return TrainingFrame.byteBlock(
          {...header, 'ok': true},
          'snapshot',
          Uint8List.fromList(utf8.encode(jsonEncode(environment.snapshot()))),
        );
      case 'restore':
        result = await environment.restore(
          _wireMap(jsonDecode(utf8.decode(frame.bytes('snapshot')))),
        );
      case 'close':
        await environment.close();
      default:
        throw const FormatException('Unsupported environment operation.');
    }
    return TrainingFrame.float32(
      {
        ...header,
        ...?result?.info,
        'ok': true,
        if (result != null) 'reward': result.reward,
        if (result != null) 'terminated': result.terminated,
        if (result != null) 'truncated': result.truncated,
      },
      {
        if (result != null)
          for (final entry in result.observations.entries)
            'observation.${entry.key}': entry.value,
      },
    );
  }

  @override
  Future<void> close() => environment.close();
}

final class GameTrainingSupervisor {
  final Future<TrainingEnvironmentEndpoint> Function(
    String runId,
    String environmentId,
    TrainingSplit purpose,
  )
  create;
  final int maxEnvironments;
  final Set<String> capabilities;
  final Map<String, Future<TrainingEnvironmentEndpoint>> _environments = {};
  final Set<String> _busy = {};
  String? _run;
  bool _hello = false, _closed = false;
  int _sequence = -1;
  int maxHeader = trainingMaxHeader, maxMessage = trainingMaxMessage;
  GameTrainingSupervisor({
    required this.create,
    this.maxEnvironments = 16,
    Set<String> capabilities = const {'structured', 'snapshot'},
  }) : capabilities = Set.unmodifiable(capabilities) {
    _boundedInt(maxEnvironments, 256, min: 1);
    if (capabilities.length > 32) {
      throw ArgumentError('Capability budget exceeded.');
    }
    for (final capability in capabilities) {
      _wireId(capability);
    }
  }
  Future<TrainingFrame> dispatch(TrainingFrame frame) async {
    final header = frame.header;
    var acquired = false;
    final envId = header['environment_id'] as String;
    try {
      if (_closed) throw StateError('Supervisor is closed.');
      final seq = header['sequence'] as int;
      if (seq <= _sequence) {
        throw StateError('Duplicate or out-of-order request sequence.');
      }
      _sequence = seq;
      final run = header['run_id'] as String;
      if (_run != null && _run != run) {
        throw StateError('Run identity differs.');
      }
      _run = run;
      if (header['operation'] == 'hello') {
        if (_hello) throw StateError('Hello already negotiated.');
        maxHeader = _boundedInt(
          header['max_header'] ?? trainingMaxHeader,
          trainingMaxHeader,
          min: 256,
        );
        maxMessage = _boundedInt(
          header['max_message'] ?? trainingMaxMessage,
          trainingMaxMessage,
          min: maxHeader + 4,
        );
        _hello = true;
        return TrainingFrame.float32({
          ...header,
          'ok': true,
          'max_header': maxHeader,
          'max_message': maxMessage,
          'capabilities': capabilities.toList(),
          'visual': false,
        }, {});
      }
      if (!_hello) throw StateError('Wire hello is required.');
      if (!_busy.add(envId)) throw StateError('Environment is busy.');
      acquired = true;
      if (!_environments.containsKey(envId)) {
        if (header['operation'] != 'reset' ||
            _environments.length >= maxEnvironments) {
          throw StateError('Environment missing or budget exceeded.');
        }
        final purpose = TrainingSplit.values.byName(
          header['purpose'] as String? ?? 'training',
        );
        final candidate = create(run, envId, purpose);
        _environments[envId] = candidate;
        try {
          await candidate;
        } catch (_) {
          _environments.remove(envId);
          rethrow;
        }
      }
      final endpoint = await _environments[envId]!;
      final response = await endpoint.request(frame);
      if (header['operation'] == 'close') {
        await endpoint.close();
        _environments.remove(envId);
      }
      return response;
    } catch (error) {
      return TrainingFrame.float32({
        ...header,
        'ok': false,
        'success': false,
        'worker_failed': false,
        'error': error.toString().substring(
          0,
          error.toString().length.clamp(0, 2048),
        ),
      }, {});
    } finally {
      if (acquired) _busy.remove(envId);
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    Object? failure;
    for (final pending in _environments.values) {
      try {
        await (await pending).close();
      } catch (error) {
        failure ??= error;
      }
    }
    _environments.clear();
    if (failure != null) {
      throw StateError('Supervisor cleanup failed: $failure');
    }
  }
}
