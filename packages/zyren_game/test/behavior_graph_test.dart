import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';

class WaitAction extends GameRuleAction {
  int ticks = 0;
  final void Function() cancelled;
  WaitAction(this.cancelled);
  @override
  BehaviorStatus tick(BehaviorContext context) {
    context.emit({'step': ++ticks});
    return ticks < 2 ? BehaviorStatus.running : BehaviorStatus.succeeded;
  }

  @override
  void cancel(BehaviorContext context) => cancelled();
}

class GuardState {
  bool switchNow = false;
}

void main() {
  test(
    'state transition cancels running state and guards cannot emit commands',
    () {
      var cancelled = 0;
      final actions = GameActionRegistry()
        ..register('wait', factory: (_) => WaitAction(() => cancelled++));
      final guard = GuardState();
      final predicates = GamePredicateRegistry()
        ..register(
          'switch',
          services: {'guard'},
          evaluate: (context, _) =>
              context.service<GuardState>('guard').switchNow,
        );
      GameRuleProgram state(String id) => GameRuleGraph(
        root: id,
        nodes: [GameRuleNode.action(id, 'wait')],
      ).compile(actions, predicates);
      final entities = GameEntityTable();
      final actor = entities.spawn('npc');
      final machine = GameStateMachine(
        states: {'idle': state('idle'), 'move': state('move')},
        transitions: [
          GameStateTransition(from: 'idle', to: 'move', predicate: 'switch'),
        ],
        initial: 'idle',
        actor: actor,
        epoch: 1,
        predicates: predicates,
        services: {'guard': guard},
      );
      expect(
        machine.step(tick: 0, epoch: 1, entities: entities),
        BehaviorStatus.running,
      );
      guard.switchNow = true;
      expect(
        machine.step(tick: 1, epoch: 1, entities: entities),
        BehaviorStatus.running,
      );
      expect(machine.state, 'move');
      expect(machine.drainEvents(), hasLength(2));
      expect(cancelled, 1);
      machine.close();
      expect(cancelled, 2);
      final bad = GamePredicateRegistry()
        ..register(
          'bad',
          evaluate: (context, _) {
            context.enqueue('move', {});
            return true;
          },
        );
      final graph = GameRuleGraph(
        root: 'bad',
        nodes: [GameRuleNode.predicate('bad', 'bad')],
      ).compile(actions, bad);
      expect(
        () => graph
            .runner(actor: actor, epoch: 1)
            .step(tick: 0, epoch: 1, entities: entities),
        throwsStateError,
      );
    },
  );
  test(
    'graph rejects cycles, unknown operations, wrong ports and oversized trees',
    () {
      final actions = GameActionRegistry();
      actions.register(
        'wait',
        ports: {'count': GamePortType.integer},
        factory: (args) => WaitAction(() {}),
      );
      final predicates = GamePredicateRegistry();
      expect(
        () => GameRuleGraph(
          root: 'a',
          nodes: [
            GameRuleNode.sequence('a', ['a']),
          ],
        ).compile(actions, predicates),
        throwsFormatException,
      );
      expect(
        () => GameRuleGraph(
          root: 'a',
          nodes: [GameRuleNode.action('a', 'missing')],
        ).compile(actions, predicates),
        throwsFormatException,
      );
      expect(
        () => GameRuleGraph(
          root: 'a',
          nodes: [
            GameRuleNode.action('a', 'wait', arguments: {'count': 'two'}),
          ],
        ).compile(actions, predicates),
        throwsFormatException,
      );
      expect(
        () => GameRuleGraph(
          root: 'a',
          nodes: [
            for (var i = 0; i < 1025; i++) GameRuleNode.sequence('n$i', []),
          ],
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'running actions keep state and cancel when entity generation changes',
    () {
      var cancelled = 0;
      final actions = GameActionRegistry()
        ..register('wait', factory: (_) => WaitAction(() => cancelled++));
      final graph = GameRuleGraph(
        root: 'wait',
        nodes: [GameRuleNode.action('wait', 'wait')],
      ).compile(actions, GamePredicateRegistry());
      final entities = GameEntityTable();
      final actor = entities.spawn('npc');
      final runner = graph.runner(actor: actor, epoch: 1);
      expect(
        runner.step(tick: 0, epoch: 1, entities: entities),
        BehaviorStatus.running,
      );
      expect(runner.drainEvents(), [
        {'step': 1},
      ]);
      entities.despawn(actor);
      entities.spawn('npc');
      expect(
        runner.step(tick: 1, epoch: 1, entities: entities),
        BehaviorStatus.failed,
      );
      expect(cancelled, 1);
      runner.close();
      expect(cancelled, 1);
    },
  );
  test(
    'declared services and bounded queues prevent unregistered state access',
    () {
      final actions = GameActionRegistry()
        ..register('wait', factory: (_) => WaitAction(() {}));
      final predicates = GamePredicateRegistry()
        ..register(
          'permitted',
          services: {'permit'},
          evaluate: (context, args) => context.service<bool>('permit'),
        );
      final graph = GameRuleGraph(
        root: 'all',
        nodes: [
          GameRuleNode.sequence('all', ['check', 'wait']),
          GameRuleNode.predicate('check', 'permitted'),
          GameRuleNode.action('wait', 'wait'),
        ],
      ).compile(actions, predicates);
      final entities = GameEntityTable();
      final actor = entities.spawn('npc');
      final runner = graph.runner(
        actor: actor,
        epoch: 1,
        services: {'permit': true},
        queueCapacity: 1,
      );
      expect(
        runner.step(tick: 0, epoch: 1, entities: entities),
        BehaviorStatus.running,
      );
      expect(
        () => runner.step(tick: 1, epoch: 1, entities: entities),
        throwsStateError,
      );
      expect(runner.status, BehaviorStatus.failed);
      final denied = GamePredicateRegistry()
        ..register(
          'read',
          evaluate: (context, args) => context.service<bool>('permit'),
        );
      final deniedGraph = GameRuleGraph(
        root: 'read',
        nodes: [GameRuleNode.predicate('read', 'read')],
      ).compile(actions, denied);
      expect(
        () => deniedGraph
            .runner(actor: actor, epoch: 1, services: {'permit': true})
            .step(tick: 0, epoch: 1, entities: entities),
        throwsStateError,
      );
    },
  );
  test(
    'step budget yields and preserves completed work; graph JSON round trips',
    () {
      var visits = 0;
      final predicates = GamePredicateRegistry()
        ..register(
          'yes',
          evaluate: (_, _) {
            visits++;
            return true;
          },
        );
      final raw = GameRuleGraph(
        root: 'all',
        nodes: [
          GameRuleNode.sequence('all', ['a', 'b']),
          GameRuleNode.predicate('a', 'yes'),
          GameRuleNode.predicate('b', 'yes'),
        ],
      );
      final graph = GameRuleGraph.fromJson(
        raw.toJson(),
      ).compile(GameActionRegistry(), predicates);
      final entities = GameEntityTable();
      final actor = entities.spawn('npc');
      final runner = graph.runner(actor: actor, epoch: 1, stepBudget: 2);
      expect(
        runner.step(tick: 0, epoch: 1, entities: entities),
        BehaviorStatus.running,
      );
      expect(
        runner.step(tick: 1, epoch: 1, entities: entities),
        BehaviorStatus.succeeded,
      );
      expect(visits, 2);
      expect(
        runner.step(tick: 2, epoch: 1, entities: entities),
        BehaviorStatus.succeeded,
      );
      expect(visits, 2);
    },
  );
}
