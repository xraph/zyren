part of '../../zyren_game.dart';

sealed class GameGameplayCommand {
  final String receipt;
  final int sequence;
  GameGameplayCommand(String receipt, {required this.sequence})
    : receipt = _id(receipt) {
    if (sequence < 0 || sequence > 0x1fffffffffffff) {
      throw ArgumentError('Invalid gameplay receipt sequence.');
    }
  }
}

final class GameTransferItem extends GameGameplayCommand {
  final String item;
  final int count;
  final GameEntityHandle to;
  final GameEntityHandle? reachActor, reachTarget;
  GameTransferItem(
    super.receipt, {
    required super.sequence,
    required this.item,
    required this.count,
    required this.to,
    this.reachActor,
    this.reachTarget,
  });
}

final class GameUseAbility extends GameGameplayCommand {
  final String ability;
  GameUseAbility(super.receipt, this.ability, {required super.sequence}) {
    _id(ability);
  }
}

final class GameInteract extends GameGameplayCommand {
  final String interaction;
  GameInteract(super.receipt, this.interaction, {required super.sequence}) {
    _id(interaction);
  }
}

final class GameCreditObjective extends GameGameplayCommand {
  final String objective;
  final int count;
  GameCreditObjective(
    super.receipt,
    this.objective, {
    required super.sequence,
    this.count = 1,
  }) {
    _id(objective);
  }
}

final class GameGameplayResult {
  final GameEntityHandle actor;
  final String receipt;
  final bool accepted;
  final Object? detail;
  const GameGameplayResult(
    this.actor,
    this.receipt,
    this.accepted, [
    this.detail,
  ]);
}

abstract interface class GameReachService {
  bool inReach(GameEntityHandle actor, GameEntityHandle target);
}

/// A monotonic per-actor high-water mark survives save/restore with constant space.
final class GameReceiptCursor {
  int _sequence;
  int get sequence => _sequence;
  GameReceiptCursor([int sequence = -1]) : _sequence = sequence {
    if (sequence < -1 || sequence > 0x1fffffffffffff) {
      throw const FormatException('Invalid receipt cursor.');
    }
  }
  Map<String, Object?> toJson() => {'sequence': sequence};
  factory GameReceiptCursor.fromJson(Map<String, Object?> data) =>
      GameReceiptCursor(_integer(data['sequence']));
}

final class GameActorRules {
  final Inventory inventory;
  final Map<String, Ability> abilities;
  final ObjectiveTracker? objectives;
  final GameReceiptCursor receipts;
  GameActorRules({
    required this.inventory,
    Map<String, Ability> abilities = const {},
    this.objectives,
    GameReceiptCursor? receipts,
  }) : abilities = Map.unmodifiable(abilities),
       receipts = receipts ?? GameReceiptCursor() {
    if (abilities.length > 64 ||
        abilities.entries.any((e) => e.key != e.value.id)) {
      throw ArgumentError('Invalid actor ability map.');
    }
  }
  List<GameComponentRecord> snapshot() => [
    GameComponentRecord('game.inventory', 1, inventory.toJson()),
    GameComponentRecord('game.receipts', 1, receipts.toJson()),
    GameComponentRecord(
      'game.abilities',
      1,
      GameAbilityCollection(abilities).toJson(),
    ),
    if (objectives != null)
      GameComponentRecord('game.objectives', 1, objectives!.toJson()),
  ];
}

/// Applies typed commands once per receipt at the shared rules phase.
final class GameGameplaySystem extends GameSystem {
  final GameReachService? reach;
  final Map<String, GameInteraction> _interactions;
  Map<String, GameInteraction> get interactions =>
      Map.unmodifiable(_interactions);
  final Map<GameEntityHandle, GameActorRules> _actors = {};
  GameSession? _session;
  GameEventSubscription? _stateRegistration;
  GameGameplaySystem({
    this.reach,
    Map<String, GameInteraction> interactions = const {},
  }) : _interactions = Map.of(interactions) {
    if (interactions.length > 1024 ||
        interactions.entries.any((e) => e.key != e.value.id)) {
      throw ArgumentError('Invalid gameplay interactions.');
    }
  }
  @override
  String get id => 'game.rules';
  @override
  GamePhase get phase => GamePhase.rules;
  @override
  void start(GameSession session) {
    if (_session != null) {
      throw StateError('Gameplay systems have one session owner.');
    }
    _session = session;
    _stateRegistration = session.registerStateCodec(
      GameGameplayStateCodec(this),
    );
  }

  void bind(GameEntityHandle actor, GameActorRules rules) {
    final session = _session;
    if (session == null ||
        !session.entities.isAlive(actor) ||
        _actors.containsKey(actor) ||
        _actors.length >= session.entities.limits.maxEntities) {
      throw StateError('Invalid gameplay actor binding.');
    }
    _actors[actor] = rules;
  }

  /// Replace a validated live topology, retaining the supplied actor owners.
  void reconcile({
    required Map<GameEntityHandle, GameActorRules> actors,
    required Map<String, GameInteraction> interactions,
  }) {
    final session = _session;
    if (session == null ||
        actors.length > session.entities.limits.maxEntities ||
        actors.keys.any((a) => !session.entities.isAlive(a)) ||
        interactions.length > 1024 ||
        interactions.entries.any(
          (e) =>
              e.key != e.value.id || !session.entities.isAlive(e.value.target),
        )) {
      throw StateError('Invalid live gameplay topology.');
    }
    for (final entry in _actors.entries) {
      if (!identical(actors[entry.key], entry.value)) {
        for (final ability in entry.value.abilities.values) {
          ability.cancel(entry.key);
        }
      }
    }
    _actors
      ..clear()
      ..addAll(actors);
    _interactions
      ..clear()
      ..addAll(interactions);
  }

  GameActorRules? actor(GameEntityHandle actor) => _actors[actor];
  @override
  void fixedUpdate(GameSession session) {
    for (final actor in _actors.keys.toList()) {
      final rules = _actors[actor]!;
      if (!session.entities.isAlive(actor)) {
        for (final ability in rules.abilities.values) {
          ability.cancel(actor);
        }
        _actors.remove(actor);
        continue;
      }
      for (final ability in rules.abilities.values) {
        if (ability.active != null && !session.events.canEmit) {
          throw StateError('Gameplay event backpressure.');
        }
        final finished = ability.advance(session.tick);
        if (finished != null) session.events.emit(session.tick, finished);
      }
    }
    for (final command in session.currentCommands) {
      final payload = command.payload;
      if (payload is! GameGameplayCommand) continue;
      final rules = _actors[command.target];
      if (rules == null || payload.sequence <= rules.receipts.sequence) {
        continue;
      }
      if (!session.events.canEmit) {
        throw StateError('Gameplay event backpressure.');
      }
      var accepted = false;
      Object? detail;
      switch (payload) {
        case GameTransferItem():
          final receiver = _actors[payload.to];
          if (receiver != null &&
              session.entities.isAlive(payload.to) &&
              (payload.reachActor == null && payload.reachTarget == null ||
                  payload.reachActor != null &&
                      payload.reachTarget != null &&
                      session.entities.isAlive(payload.reachActor!) &&
                      session.entities.isAlive(payload.reachTarget!) &&
                      reach?.inReach(
                            payload.reachActor!,
                            payload.reachTarget!,
                          ) ==
                          true)) {
            accepted = rules.inventory.transfer(
              item: payload.item,
              count: payload.count,
              to: receiver.inventory,
            );
          }
        case GameUseAbility():
          final activation = rules.abilities[payload.ability]?.tryActivate(
            actor: command.target,
            inventory: rules.inventory,
            tick: session.tick,
          );
          accepted = activation != null;
          detail = activation;
        case GameInteract():
          final interaction = interactions[payload.interaction];
          if (interaction != null && reach != null) {
            accepted = interaction.tryApply(
              actor: command.target,
              entities: session.entities,
              inventory: rules.inventory,
              receipt: payload.receipt,
              inReach: reach!.inReach(command.target, interaction.target),
            );
          }
        case GameCreditObjective():
          accepted =
              rules.objectives?.credit(
                payload.objective,
                receipt: payload.receipt,
                count: payload.count,
              ) ??
              false;
      }
      rules.receipts._sequence = payload.sequence;
      session.events.emit(
        session.tick,
        GameGameplayResult(command.target, payload.receipt, accepted, detail),
      );
    }
  }

  @override
  void pause(GameSession session) {
    for (final entry in _actors.entries) {
      for (final ability in entry.value.abilities.values) {
        ability.cancel(entry.key);
      }
    }
  }

  @override
  void dispose(GameSession session) {
    pause(session);
    _actors.clear();
    _stateRegistration?.cancel();
    _stateRegistration = null;
    _session = null;
  }
}

final class GameBehaviorEvent {
  final GameEntityHandle actor;
  final Map<String, Object?> data;
  const GameBehaviorEvent(this.actor, this.data);
}

/// Bridges bounded rule outputs to the next authoritative command tick.
final class GameBehaviorSystem extends GameSystem {
  final Map<GameEntityHandle, GameRuleRunner> _runners = {};
  GameSession? _session;
  @override
  String get id => 'game.behaviors';
  @override
  GamePhase get phase => GamePhase.decisions;
  @override
  void start(GameSession session) {
    if (_session != null) {
      throw StateError('Behavior systems have one session owner.');
    }
    _session = session;
  }

  void bind(GameRuleRunner runner) {
    final session = _session;
    if (session == null ||
        runner.epoch != session.epoch ||
        !session.entities.isAlive(runner.actor) ||
        _runners.containsKey(runner.actor) ||
        _runners.length >= session.entities.limits.maxEntities) {
      throw StateError('Invalid behavior actor binding.');
    }
    _runners[runner.actor] = runner;
  }

  @override
  void fixedUpdate(GameSession session) {
    for (final entry in _runners.entries.toList()) {
      final runner = entry.value;
      runner.step(
        tick: session.tick,
        epoch: session.epoch,
        entities: session.entities,
      );
      for (final event in runner.drainEvents()) {
        session.events.emit(session.tick, GameBehaviorEvent(entry.key, event));
      }
      for (final command in runner.drainCommands()) {
        if (!session.commands.enqueue(
          GameCommand(entry.key, session.tick + 1, command),
          session.entities,
        )) {
          throw StateError('Behavior command backpressure.');
        }
      }
      if (runner.status != BehaviorStatus.running) {
        runner.close();
        _runners.remove(entry.key);
      }
    }
  }

  void _cancel() {
    Object? failure;
    StackTrace? stack;
    for (final runner in _runners.values) {
      try {
        runner.close();
      } catch (error, trace) {
        failure ??= error;
        stack ??= trace;
      }
    }
    _runners.clear();
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }

  @override
  void pause(GameSession session) => _cancel();
  @override
  void dispose(GameSession session) {
    try {
      _cancel();
    } finally {
      _session = null;
    }
  }
}

/// Restores live rule instances against the replacement table's fresh generations.
final class GameGameplayStateCodec
    extends GameStateCodec<GamePreparedGameplay> {
  final GameGameplaySystem system;
  GameGameplayStateCodec(this.system);
  @override
  String get id => 'game.rules';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) => {
    'actors': {
      for (final entry in system._actors.entries)
        if (session.entities.isAlive(entry.key))
          entry.key.id: {
            'inventory': entry.value.inventory.toJson(),
            'receipts': entry.value.receipts.toJson(),
            'abilities': GameAbilityCollection(entry.value.abilities).toJson(),
            if (entry.value.objectives != null)
              'objectives': entry.value.objectives!.toJson(),
          },
    },
    'interactions': {
      for (final entry in system._interactions.entries)
        if (session.entities.isAlive(entry.value.target))
          entry.key: {
            'target': entry.value.target.id,
            'requiredItems': entry.value.requiredItems,
            'consumeItems': entry.value.consumeItems,
            'receiptCapacity': entry.value.receiptCapacity,
            'receipts': entry.value._receipts.toList(),
          },
    },
  };
  @override
  GamePreparedGameplay prepare(GameSession session, Map<String, Object?> data) {
    final actors = _map(data['actors']),
        interactions = _map(data['interactions']);
    if (actors.length > session.entities.limits.maxEntities ||
        interactions.length > 1024) {
      throw const FormatException('Gameplay state exceeds limits.');
    }
    final rules = actors.map((id, value) {
      final fields = _map(value);
      return MapEntry(
        _id(id),
        GameActorRules(
          inventory: Inventory.fromJson(_map(fields['inventory'])),
          receipts: GameReceiptCursor.fromJson(_map(fields['receipts'])),
          abilities: GameAbilityCollection.fromJson(
            _map(fields['abilities']),
          ).abilities,
          objectives: fields['objectives'] == null
              ? null
              : ObjectiveTracker.fromJson(_map(fields['objectives'])),
        ),
      );
    });
    final staged = interactions.map((id, value) {
      final fields = _map(value);
      final rule = GameInteraction(
        id: id,
        target: GameEntityHandle(_string(fields['target']), 1),
        requiredItems: _itemMap(fields['requiredItems']),
        consumeItems: fields['consumeItems'] as bool,
        receiptCapacity: _integer(fields['receiptCapacity']),
      );
      final receipts = _list(
        fields['receipts'],
      ).map((v) => _id(_string(v))).toList();
      if (receipts.length > rule.receiptCapacity ||
          receipts.toSet().length != receipts.length) {
        throw const FormatException('Invalid interaction receipts.');
      }
      rule._receipts.addAll(receipts);
      return MapEntry(id, rule);
    });
    return GamePreparedGameplay(rules, staged);
  }

  @override
  void commit(GameSession session, GamePreparedGameplay prepared) {
    final actors = <GameEntityHandle, GameActorRules>{};
    for (final entry in prepared.actors.entries) {
      final entity = session.entities._entities[entry.key];
      if (entity == null) throw StateError('Saved gameplay actor is missing.');
      actors[entity.handle] = entry.value;
    }
    final interactions = <String, GameInteraction>{};
    for (final entry in prepared.interactions.entries) {
      final source = entry.value;
      final entity = session.entities._entities[source.target.id];
      if (entity == null) {
        throw StateError('Saved interaction target is missing.');
      }
      interactions[entry.key] = GameInteraction(
        id: source.id,
        target: entity.handle,
        requiredItems: source.requiredItems,
        consumeItems: source.consumeItems,
        receiptCapacity: source.receiptCapacity,
      ).._receipts.addAll(source._receipts);
    }
    system.pause(session);
    system._actors
      ..clear()
      ..addAll(actors);
    system._interactions
      ..clear()
      ..addAll(interactions);
  }
}

final class GamePreparedGameplay {
  final Map<String, GameActorRules> actors;
  final Map<String, GameInteraction> interactions;
  GamePreparedGameplay(this.actors, this.interactions);
}
