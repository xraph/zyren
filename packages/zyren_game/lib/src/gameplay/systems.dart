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
  GameTransferItem(
    super.receipt, {
    required super.sequence,
    required this.item,
    required this.count,
    required this.to,
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
  final Map<String, GameInteraction> interactions;
  final Map<GameEntityHandle, GameActorRules> _actors = {};
  GameSession? _session;
  GameGameplaySystem({
    this.reach,
    Map<String, GameInteraction> interactions = const {},
  }) : interactions = Map.unmodifiable(interactions) {
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
          if (receiver != null && session.entities.isAlive(payload.to)) {
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
