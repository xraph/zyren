part of '../../zyren_game.dart';

enum BehaviorStatus { running, succeeded, failed }

enum GamePortType { boolean, integer, number, string }

enum GameRuleKind { sequence, selector, inverter, action, predicate }

abstract class GameRuleAction {
  BehaviorStatus tick(BehaviorContext context);
  void cancel(BehaviorContext context) {}
}

final class GameRuleCommand {
  final GameEntityHandle actor;
  final int tick, epoch;
  final String action;
  final Map<String, Object?> arguments;
  GameRuleCommand._(
    this.actor,
    this.tick,
    this.epoch,
    this.action,
    this.arguments,
  );
}

/// Only registered services are visible. Outputs are bounded data queues.
final class BehaviorContext {
  final GameEntityHandle actor;
  final int tick, epoch;
  final Map<String, Object> _services;
  final Set<String> _allowed;
  final GameRuleRunner _runner;
  bool _open = true;
  final bool _cancelling, _readOnly;
  BehaviorContext._(
    this._runner,
    this.tick,
    this._allowed, {
    bool cancelling = false,
    bool readOnly = false,
  }) : actor = _runner.actor,
       epoch = _runner.epoch,
       _services = _runner._services,
       _cancelling = cancelling,
       _readOnly = readOnly;
  T service<T extends Object>(String id) {
    if (!_open || !_allowed.contains(id) || _services[id] is! T) {
      throw StateError(
        'Undeclared, missing or incompatible behavior service: $id.',
      );
    }
    return _services[id] as T;
  }

  void emit(Map<String, Object?> event) {
    if (!_open ||
        _cancelling ||
        _readOnly ||
        _runner._events.length >= _runner.queueCapacity) {
      throw StateError('Behavior event queue is unavailable or full.');
    }
    _runner._events.add(_json(event));
  }

  void enqueue(String action, Map<String, Object?> arguments) {
    if (!_open ||
        _cancelling ||
        _readOnly ||
        _runner._commands.length >= _runner.queueCapacity) {
      throw StateError('Behavior action queue is unavailable or full.');
    }
    _runner._commands.add(
      GameRuleCommand._(actor, tick, epoch, _id(action), _json(arguments)),
    );
  }
}

final class _RuleOperation {
  final Map<String, GamePortType> ports;
  final Set<String> services;
  final GameRuleAction Function(Map<String, Object?>)? factory;
  final bool Function(BehaviorContext, Map<String, Object?>)? predicate;
  _RuleOperation(
    Map<String, GamePortType> ports,
    Set<String> services, {
    this.factory,
    this.predicate,
  }) : ports = Map.unmodifiable(ports),
       services = Set.unmodifiable(services) {
    if (ports.length > 64 || services.length > 64) {
      throw const FormatException(
        'Rule operation exceeds port/service limits.',
      );
    }
    ports.keys.forEach(_id);
    services.forEach(_id);
  }
  void validate(Map<String, Object?> arguments) {
    if (arguments.length != ports.length) {
      throw const FormatException('Rule port count mismatch.');
    }
    for (final port in ports.entries) {
      final value = arguments[port.key];
      final valid = switch (port.value) {
        GamePortType.boolean => value is bool,
        GamePortType.integer => value is int,
        GamePortType.number => value is num && value.isFinite,
        GamePortType.string => value is String,
      };
      if (!valid) {
        throw FormatException('Rule port type mismatch: ${port.key}.');
      }
    }
  }
}

final class GameActionRegistry {
  final Map<String, _RuleOperation> _operations = {};
  Map<String, Map<String, GamePortType>> get ports => Map.unmodifiable({
    for (final entry in _operations.entries) entry.key: entry.value.ports,
  });
  void register(
    String id, {
    Map<String, GamePortType> ports = const {},
    Set<String> services = const {},
    required GameRuleAction Function(Map<String, Object?>) factory,
  }) {
    _id(id);
    if (_operations.length >= 256 || _operations.containsKey(id)) {
      throw StateError('Duplicate or excess game action.');
    }
    _operations[id] = _RuleOperation(ports, services, factory: factory);
  }
}

final class GamePredicateRegistry {
  final Map<String, _RuleOperation> _operations = {};
  Map<String, Map<String, GamePortType>> get ports => Map.unmodifiable({
    for (final entry in _operations.entries) entry.key: entry.value.ports,
  });
  void register(
    String id, {
    Map<String, GamePortType> ports = const {},
    Set<String> services = const {},
    required bool Function(BehaviorContext, Map<String, Object?>) evaluate,
  }) {
    _id(id);
    if (_operations.length >= 256 || _operations.containsKey(id)) {
      throw StateError('Duplicate or excess game predicate.');
    }
    _operations[id] = _RuleOperation(ports, services, predicate: evaluate);
  }
}

final class GameRuleNode {
  final String id;
  final GameRuleKind kind;
  final List<String> children;
  final String? operation;
  final Map<String, Object?> arguments;
  GameRuleNode({
    required String id,
    required this.kind,
    List<String> children = const [],
    this.operation,
    Map<String, Object?> arguments = const {},
  }) : id = _id(id),
       children = List.unmodifiable(children),
       arguments = _json(arguments) {
    if (children.length > 256) {
      throw const FormatException('Rule children limit exceeded.');
    }
    children.forEach(_id);
    if (operation != null) _id(operation!);
    if ((kind == GameRuleKind.action || kind == GameRuleKind.predicate) &&
            (operation == null || children.isNotEmpty) ||
        kind == GameRuleKind.inverter && children.length != 1 ||
        (kind == GameRuleKind.sequence ||
                kind == GameRuleKind.selector ||
                kind == GameRuleKind.inverter) &&
            (operation != null || arguments.isNotEmpty)) {
      throw const FormatException('Invalid rule node shape.');
    }
  }
  factory GameRuleNode.sequence(String id, List<String> children) =>
      GameRuleNode(id: id, kind: GameRuleKind.sequence, children: children);
  factory GameRuleNode.selector(String id, List<String> children) =>
      GameRuleNode(id: id, kind: GameRuleKind.selector, children: children);
  factory GameRuleNode.action(
    String id,
    String operation, {
    Map<String, Object?> arguments = const {},
  }) => GameRuleNode(
    id: id,
    kind: GameRuleKind.action,
    operation: operation,
    arguments: arguments,
  );
  factory GameRuleNode.predicate(
    String id,
    String operation, {
    Map<String, Object?> arguments = const {},
  }) => GameRuleNode(
    id: id,
    kind: GameRuleKind.predicate,
    operation: operation,
    arguments: arguments,
  );
  Map<String, Object?> toJson() => {
    'id': id,
    'kind': kind.name,
    'children': children,
    if (operation != null) 'operation': operation,
    'arguments': arguments,
  };
  factory GameRuleNode.fromJson(Map<String, Object?> data) => GameRuleNode(
    id: _string(data['id']),
    kind: GameRuleKind.values.firstWhere(
      (k) => k.name == data['kind'],
      orElse: () => throw const FormatException('Unknown rule kind.'),
    ),
    children: _list(data['children'] ?? []).map(_string).toList(),
    operation: data['operation'] as String?,
    arguments: _map(data['arguments'] ?? <String, Object?>{}),
  );
}

final class GameRuleGraph {
  final String root;
  final List<GameRuleNode> nodes;
  GameRuleGraph({required String root, required List<GameRuleNode> nodes})
    : root = _id(root),
      nodes = List.unmodifiable(nodes) {
    if (nodes.isEmpty || nodes.length > 1024) {
      throw const FormatException('Rule graph needs 1..1024 nodes.');
    }
  }
  Map<String, Object?> toJson() => {
    'version': 1,
    'root': root,
    'nodes': nodes.map((n) => n.toJson()).toList(),
  };
  factory GameRuleGraph.fromJson(Map<String, Object?> data) {
    if (data['version'] != 1) {
      throw const FormatException('Unsupported rule graph version.');
    }
    return GameRuleGraph(
      root: _string(data['root']),
      nodes: _list(
        data['nodes'],
      ).map((n) => GameRuleNode.fromJson(_map(n))).toList(),
    );
  }
  GameRuleProgram compile(
    GameActionRegistry actions,
    GamePredicateRegistry predicates,
  ) {
    final byId = <String, GameRuleNode>{},
        operations = <String, _RuleOperation>{};
    for (final node in nodes) {
      if (byId.containsKey(node.id)) {
        throw const FormatException('Duplicate rule node.');
      }
      byId[node.id] = node;
      if (node.operation case final operation?) {
        final registered = (node.kind == GameRuleKind.action
            ? actions._operations
            : predicates._operations)[operation];
        if (registered == null) {
          throw FormatException('Unregistered rule operation: $operation.');
        }
        registered.validate(node.arguments);
        operations[node.id] = registered;
      }
    }
    final visited = <String>{};
    var maxDepth = 0;
    void visit(String id, int depth) {
      final node = byId[id];
      if (node == null || !visited.add(id) || depth > 32) {
        throw const FormatException(
          'Missing, cyclic, shared or too deep rule node.',
        );
      }
      if (depth > maxDepth) maxDepth = depth;
      for (final child in node.children) {
        visit(child, depth + 1);
      }
    }

    visit(root, 1);
    if (visited.length != nodes.length) {
      throw const FormatException('Unreachable rule nodes.');
    }
    return GameRuleProgram._(
      root,
      Map.unmodifiable(byId),
      Map.unmodifiable(operations),
      maxDepth,
    );
  }
}

final class GameRuleProgram {
  final String root;
  final Map<String, GameRuleNode> _nodes;
  final Map<String, _RuleOperation> _operations;
  final int _depth;
  GameRuleProgram._(this.root, this._nodes, this._operations, this._depth);
  GameRuleRunner runner({
    required GameEntityHandle actor,
    required int epoch,
    Map<String, Object> services = const {},
    int stepBudget = 64,
    int queueCapacity = 256,
  }) =>
      GameRuleRunner._(this, actor, epoch, services, stepBudget, queueCapacity);
}

final class GameRuleRunner {
  final GameRuleProgram program;
  final GameEntityHandle actor;
  final int epoch, stepBudget, queueCapacity;
  final Map<String, Object> _services;
  final Map<String, int> _cursor = {};
  final Map<String, GameRuleAction> _running = {};
  final List<Map<String, Object?>> _events = [];
  final List<GameRuleCommand> _commands = [];
  int _lastTick = -1, _remaining = 0;
  bool _closed = false;
  BehaviorStatus _status = BehaviorStatus.running;
  BehaviorStatus get status => _status;
  GameRuleRunner._(
    this.program,
    this.actor,
    this.epoch,
    Map<String, Object> services,
    this.stepBudget,
    this.queueCapacity,
  ) : _services = Map.unmodifiable(services) {
    _limit(stepBudget, 4096, 'rule step budget');
    _limit(queueCapacity, 4096, 'rule output capacity');
    if (epoch < 0 || services.length > 128 || stepBudget < program._depth) {
      throw ArgumentError('Invalid rule runtime limits.');
    }
    for (final operation in program._operations.values) {
      if (!services.keys.toSet().containsAll(operation.services)) {
        throw StateError('Missing declared behavior services.');
      }
    }
  }
  List<Map<String, Object?>> drainEvents() {
    final result = List<Map<String, Object?>>.unmodifiable(_events);
    _events.clear();
    return result;
  }

  List<GameRuleCommand> drainCommands() {
    final result = List<GameRuleCommand>.unmodifiable(_commands);
    _commands.clear();
    return result;
  }

  BehaviorStatus step({
    required int tick,
    required int epoch,
    required GameEntityTable entities,
  }) {
    if (_closed) return BehaviorStatus.failed;
    if (epoch != this.epoch || !entities.isAlive(actor)) {
      close();
      return _status = BehaviorStatus.failed;
    }
    if (tick < 0 || tick <= _lastTick) {
      throw StateError('Rule ticks must increase.');
    }
    _lastTick = tick;
    if (status != BehaviorStatus.running) return status;
    _remaining = stepBudget;
    try {
      return _status = _visit(program.root);
    } catch (error, stack) {
      _status = BehaviorStatus.failed;
      try {
        close();
      } catch (_) {
        /* Preserve the initiating rule failure. */
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  BehaviorStatus _visit(String id) {
    if (_remaining-- <= 0) return BehaviorStatus.running;
    final node = program._nodes[id]!;
    switch (node.kind) {
      case GameRuleKind.action:
      case GameRuleKind.predicate:
        final operation = program._operations[id]!;
        final context = BehaviorContext._(
          this,
          _lastTick,
          operation.services,
          readOnly: node.kind == GameRuleKind.predicate,
        );
        try {
          if (node.kind == GameRuleKind.predicate) {
            return operation.predicate!(context, node.arguments)
                ? BehaviorStatus.succeeded
                : BehaviorStatus.failed;
          }
          final action = _running.putIfAbsent(
            id,
            () => operation.factory!(node.arguments),
          );
          final result = action.tick(context);
          if (result != BehaviorStatus.running) _running.remove(id);
          return result;
        } finally {
          context._open = false;
        }
      case GameRuleKind.inverter:
        return switch (_visit(node.children.single)) {
          BehaviorStatus.running => BehaviorStatus.running,
          BehaviorStatus.succeeded => BehaviorStatus.failed,
          BehaviorStatus.failed => BehaviorStatus.succeeded,
        };
      case GameRuleKind.sequence:
      case GameRuleKind.selector:
        var index = _cursor[id] ?? 0;
        while (index < node.children.length) {
          final result = _visit(node.children[index]);
          if (result == BehaviorStatus.running) {
            _cursor[id] = index;
            return result;
          }
          if (node.kind == GameRuleKind.sequence &&
                  result == BehaviorStatus.failed ||
              node.kind == GameRuleKind.selector &&
                  result == BehaviorStatus.succeeded) {
            _cursor.remove(id);
            return result;
          }
          _cursor[id] = ++index;
        }
        _cursor.remove(id);
        return node.kind == GameRuleKind.sequence
            ? BehaviorStatus.succeeded
            : BehaviorStatus.failed;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    Object? failure;
    StackTrace? trace;
    for (final entry in _running.entries.toList()) {
      final context = BehaviorContext._(
        this,
        _lastTick,
        program._operations[entry.key]!.services,
        cancelling: true,
      );
      try {
        entry.value.cancel(context);
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      } finally {
        context._open = false;
      }
    }
    _running.clear();
    _cursor.clear();
    _events.clear();
    _commands.clear();
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}
