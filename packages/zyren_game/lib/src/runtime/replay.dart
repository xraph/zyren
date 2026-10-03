part of '../../zyren_game.dart';

/// Records only commands admitted by the simulation queue.
final class GameReplay {
  final String buildId;
  final int seed, capacity;
  final List<Map<String, Object?>> _actions = [];
  GameReplay({
    required String buildId,
    required this.seed,
    this.capacity = 100000,
  }) : buildId = _id(buildId) {
    _limit(capacity, 1000000, 'capacity');
  }
  List<Map<String, Object?>> get actions => List.unmodifiable(_actions);
  bool accept(GameSession session, GameCommand<Map<String, Object?>> command) {
    if (session.project.buildId != buildId || session.seed != seed) {
      throw StateError('Replay identity differs.');
    }
    if (_actions.length >= capacity) {
      throw StateError('Replay action budget exceeded.');
    }
    final payload = _json(command.payload);
    if (!session.commands.enqueue(
      GameCommand(command.target, command.applicationTick, payload),
      session.entities,
    )) {
      return false;
    }
    _actions.add(
      Map.unmodifiable({
        'id': command.target.id,
        'tick': command.applicationTick,
        'payload': payload,
      }),
    );
    return true;
  }

  String encode() {
    final source = jsonEncode({
      'schemaVersion': 1,
      'buildId': buildId,
      'seed': seed,
      'actions': _actions,
    });
    _checkSource(source);
    return source;
  }

  factory GameReplay.decode(String source) {
    _checkSource(source);
    final json = _map(jsonDecode(source));
    if (json['schemaVersion'] != 1) {
      throw FormatException('Unsupported replay.');
    }
    final replay = GameReplay(
      buildId: _string(json['buildId']),
      seed: _integer(json['seed']),
    );
    for (final item in _list(json['actions'])) {
      final row = _map(item);
      _id(_string(row['id']));
      if (_integer(row['tick']) < 0 ||
          replay._actions.length >= replay.capacity) {
        throw FormatException('Invalid replay action.');
      }
      replay._actions.add(
        Map.unmodifiable({
          'id': row['id'],
          'tick': row['tick'],
          'payload': _json(_map(row['payload'])),
        }),
      );
    }
    return replay;
  }
  void enqueue(GameSession session) {
    if (session.project.buildId != buildId || session.seed != seed) {
      throw StateError('Replay identity differs.');
    }
    session._start();
    final commands = <GameCommand<Map<String, Object?>>>[];
    for (final row in _actions) {
      final actor = session.entities._entities[_string(row['id'])];
      if (actor == null) throw StateError('Replay actor is absent.');
      commands.add(
        GameCommand(actor.handle, _integer(row['tick']), _map(row['payload'])),
      );
    }
    if (session.commands.length + commands.length >
            session.commands.limits.maxQueuedCommands ||
        commands.any((c) => c.applicationTick <= session.commands._lastTick)) {
      throw StateError('Replay queue cannot admit action log.');
    }
    for (final command in commands) {
      session.commands.enqueue(command, session.entities);
    }
  }
}
