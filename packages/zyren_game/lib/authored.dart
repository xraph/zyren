/// Bind authored definitions to the shared gameplay and behavior runtime.
library;

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'zyren_game.dart';

abstract interface class GameAuthoredWorld
    implements GameReachService, GameRuleSpatialFacts {
  bool setActive(GameEntityHandle actor, GameEntityHandle target, bool active);
  bool possess(GameEntityHandle actor, GameEntityHandle target);
}

/// One adapter owns definition construction. Inventory and rule logic stay in
/// their existing systems; this adapter only binds identities and dispatches.
final class GameAuthoredGameplay extends GameSystem implements GameRuleFacts {
  final GameRuleLibrary library;
  final GameAuthoredWorld world;
  final void Function(GameRuleCommand command)? dispatchCustomCommand;
  GameGameplaySystem? _gameplay;
  GameGameplaySystem get gameplay =>
      _gameplay ?? (throw StateError('Authored gameplay is not started.'));
  final _definitions = <GameEntityHandle, GameRuleDefinition>{};
  final _machineDefinitions = <GameEntityHandle, GameStateMachineDefinition>{};
  final _runners = <GameEntityHandle, GameRuleRunner>{};
  final _machines = <GameEntityHandle, GameStateMachine>{};
  final _finished = <GameEntityHandle>{};
  final _machineStates = <GameEntityHandle, String>{};
  final _machineStatuses = <GameEntityHandle, BehaviorStatus>{};
  final _applied = <GameEntityHandle, Set<String>>{};
  final _sequences = <GameEntityHandle, int>{};
  final _pending = <String, (GameEntityHandle, String)>{};
  final int pendingCapacity;
  GameSession? _session;
  GameEventSubscription? _events, _stateCodec;
  int _epoch = -1;
  GameAuthoredGameplay({
    required this.library,
    required this.world,
    this.dispatchCustomCommand,
    this.pendingCapacity = 256,
  }) {
    if (pendingCapacity < 1 || pendingCapacity > 4096) {
      throw ArgumentError('Invalid authored command capacity.');
    }
  }
  @override
  String get id => 'game.authored';
  @override
  GamePhase get phase => GamePhase.rules;
  Map<GameEntityHandle, String> get states => Map.unmodifiable(
    _machines.map((key, value) => MapEntry(key, value.state)),
  );
  Map<String, Object> get _services => {
    'game.facts': this,
    'game.spatial': world,
  };

  @override
  void start(GameSession session) {
    if (_session != null) {
      throw StateError('Authored gameplay already has an owner.');
    }
    _session = session;
    _epoch = session.epoch;
    final interactions = <String, GameInteraction>{};
    final handles = {
      for (final e in session.entities.entities) e.handle.id: e.handle,
    };
    for (final entity in session.entities.entities) {
      for (final record in entity.components) {
        switch (record.type) {
          case 'game.interaction':
            final definition = GameInteractionDefinition.fromJson(record.data);
            final target = handles[definition.target ?? entity.handle.id];
            if (target == null || interactions.containsKey(definition.id)) {
              throw StateError(
                'Interaction identities must be unique and live.',
              );
            }
            interactions[definition.id] = definition.instantiate(target);
          case 'game.rules':
            _definitions[entity.handle] = GameRuleDefinition.fromJson(
              record.data,
            );
          case 'game.state-machine':
            _machineDefinitions[entity.handle] =
                GameStateMachineDefinition.fromJson(record.data);
        }
      }
    }
    _gameplay = GameGameplaySystem(reach: world, interactions: interactions)
      ..start(session);
    for (final entity in session.entities.entities) {
      Map<String, Object?>? data(String type) =>
          entity.components.where((c) => c.type == type).firstOrNull?.data;
      final inventory = data('game.inventory'),
          abilities = data('game.abilities'),
          objectives = data('game.objectives');
      gameplay.bind(
        entity.handle,
        GameActorRules(
          inventory: inventory == null
              ? Inventory(capacity: 64)
              : Inventory.fromJson(inventory),
          abilities: abilities == null
              ? {}
              : GameAbilityCollection.fromJson(abilities).abilities,
          objectives: objectives == null
              ? null
              : ObjectiveTracker.fromJson(objectives),
        ),
      );
    }
    _stateCodec = session.registerStateCodec(_AuthoredState(this));
    _events = session.events.listen((event) {
      final payload = event.payload;
      if (payload is GameGameplayResult) {
        final pending = _pending.remove(payload.receipt);
        if (payload.accepted &&
            pending != null &&
            session.entities.isAlive(pending.$1)) {
          _applied.putIfAbsent(pending.$1, () => {}).add(pending.$2);
        }
      }
    });
  }

  GameEntityHandle? _handle(String id) => _session!.entities.entities
      .where((e) => e.handle.id == id)
      .firstOrNull
      ?.handle;
  int _next(GameEntityHandle actor) {
    final saved = gameplay.actor(actor)?.receipts.sequence ?? -1;
    final next =
        ((_sequences[actor] ?? -1) > saved ? _sequences[actor]! : saved) + 1;
    _sequences[actor] = next;
    return next;
  }

  String _receipt(GameEntityHandle actor, int sequence) =>
      'authored:${sha256.convert(utf8.encode(actor.id))}:${actor.generation}:$sequence';
  bool _enqueue(GameEntityHandle actor, GameGameplayCommand command) {
    final session = _session!;
    return session.commands.enqueue(
      GameCommand(actor, session.tick + 1, command),
      session.entities,
    );
  }

  void _requireEnqueue(GameEntityHandle actor, GameGameplayCommand command) {
    if (!_enqueue(actor, command)) {
      throw StateError('Authored gameplay command backpressure.');
    }
  }

  bool interact(GameEntityHandle actor, String interaction) {
    final session = _session;
    if (session == null ||
        session.paused ||
        session.isClosed ||
        !session.entities.isAlive(actor) ||
        !gameplay.interactions.containsKey(interaction) ||
        _pending.length >= pendingCapacity) {
      return false;
    }
    final sequence = _next(actor),
        receipt = _receipt(actor, _sequences[actor]!);
    if (!_enqueue(
      actor,
      GameInteract(receipt, interaction, sequence: sequence),
    )) {
      return false;
    }
    _pending[receipt] = (actor, interaction);
    return true;
  }

  void _dispatch(GameRuleCommand command) {
    final session = _session!, actor = command.actor, args = command.arguments;
    if (command.epoch != session.epoch || !session.entities.isAlive(actor)) {
      return;
    }
    switch (command.action) {
      case 'game.interact':
        interact(actor, args['interaction'] as String);
      case 'game.consume-interaction':
        _applied[actor]?.remove(args['interaction']);
      case 'game.possess':
        final target = _handle(args['target'] as String);
        if (target != null) world.possess(actor, target);
      case 'game.set-active':
        final target = _handle(args['target'] as String);
        if (target != null) {
          world.setActive(actor, target, args['active'] as bool);
        }
      case 'game.credit-objective':
        final sequence = _next(actor);
        _requireEnqueue(
          actor,
          GameCreditObjective(
            _receipt(actor, sequence),
            args['objective'] as String,
            sequence: sequence,
            count: args['count'] as int,
          ),
        );
      case 'game.use-ability':
        final sequence = _next(actor);
        _requireEnqueue(
          actor,
          GameUseAbility(
            _receipt(actor, sequence),
            args['ability'] as String,
            sequence: sequence,
          ),
        );
      case 'game.transfer-item':
      case 'game.collect-item':
        final collect = command.action == 'game.collect-item';
        final other = _handle(args[collect ? 'source' : 'target'] as String);
        if (other == null || !world.inReach(actor, other)) return;
        final source = collect ? other : actor,
            target = collect ? actor : other;
        final sequence = _next(source);
        _requireEnqueue(
          source,
          GameTransferItem(
            _receipt(source, sequence),
            sequence: sequence,
            item: args['item'] as String,
            count: args['count'] as int,
            to: target,
            reachActor: actor,
            reachTarget: other,
          ),
        );
      default:
        final dispatch = dispatchCustomCommand;
        if (dispatch == null) {
          throw StateError('No host dispatch for ${command.action}.');
        }
        dispatch(command);
    }
  }

  @override
  void fixedUpdate(GameSession session) {
    if (_epoch != session.epoch) {
      _cancel();
      _epoch = session.epoch;
    }
    for (final command in session.currentCommands) {
      if (command.payload case final GameRuleCommand rule) _dispatch(rule);
    }
    gameplay.fixedUpdate(session);
    for (final entry in _definitions.entries) {
      if (_finished.contains(entry.key) ||
          !session.entities.isAlive(entry.key)) {
        continue;
      }
      final runner = _runners.putIfAbsent(
        entry.key,
        () => entry.value.graph
            .compile(library.actions, library.predicates)
            .runner(
              actor: entry.key,
              epoch: session.epoch,
              services: _services,
            ),
      );
      final status = runner.step(
        tick: session.tick,
        epoch: session.epoch,
        entities: session.entities,
      );
      _outputs(
        session,
        entry.key,
        runner.drainEvents(),
        runner.drainCommands(),
      );
      if (status != BehaviorStatus.running) {
        runner.close();
        _runners.remove(entry.key);
        if (!entry.value.repeat) _finished.add(entry.key);
      }
    }
    for (final entry in _machineDefinitions.entries) {
      if (!session.entities.isAlive(entry.key)) continue;
      final machine = _machines.putIfAbsent(entry.key, () {
        final machine =
            GameStateMachineDefinition(
              initial: _machineStates[entry.key] ?? entry.value.initial,
              states: entry.value.states,
              transitions: entry.value.transitions,
            ).instantiate(
              actor: entry.key,
              epoch: session.epoch,
              actions: library.actions,
              predicates: library.predicates,
              services: _services,
            );
        final status = _machineStatuses[entry.key];
        if (status != null && status != BehaviorStatus.running) {
          machine.restoreTerminalStatus(status);
        }
        return machine;
      });
      machine.step(
        tick: session.tick,
        epoch: session.epoch,
        entities: session.entities,
      );
      _machineStates[entry.key] = machine.state;
      _machineStatuses[entry.key] = machine.status;
      _outputs(
        session,
        entry.key,
        machine.drainEvents(),
        machine.drainCommands(),
      );
    }
  }

  void _outputs(
    GameSession session,
    GameEntityHandle actor,
    List<Map<String, Object?>> events,
    List<GameRuleCommand> commands,
  ) {
    for (final event in events) {
      session.events.emit(session.tick, GameBehaviorEvent(actor, event));
    }
    for (final command in commands) {
      if (!session.commands.enqueue(
        GameCommand(actor, session.tick + 1, command),
        session.entities,
      )) {
        throw StateError('Authored behavior command backpressure.');
      }
    }
  }

  @override
  bool hasItem(GameEntityHandle actor, String item, int count) =>
      count > 0 && (gameplay.actor(actor)?.inventory.count(item) ?? 0) >= count;
  @override
  bool interactionApplied(GameEntityHandle actor, String interaction) =>
      _applied[actor]?.contains(interaction) ?? false;
  @override
  bool objectiveComplete(GameEntityHandle actor, String objective) {
    final tracker = gameplay.actor(actor)?.objectives,
        target = gameplay.actor(actor)?.objectives?.targets[objective];
    return tracker != null &&
        target != null &&
        (tracker.progress[objective] ?? 0) >= target;
  }

  void _cancel() {
    for (final runner in _runners.values) {
      runner.close();
    }
    for (final machine in _machines.values) {
      machine.close();
    }
    _runners.clear();
    _machines.clear();
    _pending.clear();
  }

  @override
  void pause(GameSession session) {
    _cancel();
    _gameplay?.pause(session);
  }

  @override
  void dispose(GameSession session) {
    _cancel();
    _events?.cancel();
    _stateCodec?.cancel();
    _gameplay?.dispose(session);
    _gameplay = null;
    _session = null;
    _definitions.clear();
    _machineDefinitions.clear();
    _finished.clear();
    _machineStates.clear();
    _machineStatuses.clear();
    _applied.clear();
    _sequences.clear();
  }
}

final class _AuthoredState extends GameStateCodec<Map<String, Object?>> {
  final GameAuthoredGameplay owner;
  _AuthoredState(this.owner);
  @override
  String get id => 'game.authored';
  @override
  int get version => 1;
  @override
  Map<String, Object?> capture(GameSession session) {
    if (session.commands.length != 0 ||
        owner._pending.isNotEmpty ||
        owner._runners.values.any((r) => r.status == BehaviorStatus.running) ||
        owner._machines.values.any((m) => m.status == BehaviorStatus.running)) {
      throw StateError(
        'Pause authored behavior before saving pending or running actions.',
      );
    }
    return {
      'finished': [for (final actor in owner._finished) actor.id],
      'applied': {
        for (final entry in owner._applied.entries)
          entry.key.id: entry.value.toList(),
      },
      'states': {
        for (final entry in owner._machineStates.entries)
          entry.key.id: {
            'state': entry.value,
            'status':
                (owner._machineStatuses[entry.key] ?? BehaviorStatus.running)
                    .name,
          },
      },
    };
  }

  @override
  Map<String, Object?> prepare(GameSession session, Map<String, Object?> data) {
    final finished = List<String>.from(data['finished'] as List);
    final applied = Map<String, Object?>.from(data['applied'] as Map);
    final states = Map<String, Object?>.from(data['states'] as Map);
    final definitions = {
      for (final e in owner._definitions.entries) e.key.id: e.value,
    };
    final machines = {
      for (final e in owner._machineDefinitions.entries) e.key.id: e.value,
    };
    if (finished.toSet().length != finished.length ||
        !definitions.keys.toSet().containsAll(finished) ||
        applied.length > session.entities.limits.maxEntities ||
        !machines.keys.toSet().containsAll(states.keys)) {
      throw const FormatException('Invalid authored state identities.');
    }
    for (final entry in applied.entries) {
      final ids = List<String>.from(entry.value as List);
      if (owner._handle(entry.key) == null ||
          ids.length > 1024 ||
          ids.toSet().length != ids.length ||
          !owner.gameplay.interactions.keys.toSet().containsAll(ids)) {
        throw const FormatException('Invalid interaction state.');
      }
    }
    for (final entry in states.entries) {
      final state = entry.value as Map;
      if (!machines[entry.key]!.states.containsKey(state['state']) ||
          !BehaviorStatus.values.any((v) => v.name == state['status'])) {
        throw const FormatException('Invalid machine state.');
      }
    }
    return Map<String, Object?>.from(jsonDecode(jsonEncode(data)) as Map);
  }

  @override
  void commit(GameSession session, Map<String, Object?> prepared) {
    owner._cancel();
    final definitions = {
      for (final e in owner._definitions.entries) e.key.id: e.value,
    };
    final machines = {
      for (final e in owner._machineDefinitions.entries) e.key.id: e.value,
    };
    GameEntityHandle handle(String id) =>
        owner._handle(id) ??
        (throw StateError('Saved authored actor is missing.'));
    owner._definitions
      ..clear()
      ..addAll({for (final e in definitions.entries) handle(e.key): e.value});
    owner._machineDefinitions
      ..clear()
      ..addAll({for (final e in machines.entries) handle(e.key): e.value});
    owner._finished
      ..clear()
      ..addAll((prepared['finished'] as List).cast<String>().map(handle));
    owner._applied
      ..clear()
      ..addAll({
        for (final e in (prepared['applied'] as Map).entries)
          handle(e.key as String): Set<String>.from(e.value as List),
      });
    owner._machineStates.clear();
    owner._machineStatuses.clear();
    for (final e in (prepared['states'] as Map).entries) {
      final actor = handle(e.key as String), state = e.value as Map;
      owner._machineStates[actor] = state['state'] as String;
      owner._machineStatuses[actor] = BehaviorStatus.values.byName(
        state['status'] as String,
      );
    }
    owner._sequences.clear();
    owner._epoch = session.epoch;
  }
}
