import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_game/zyren_game.dart';

void main() {
  test(
    'authored state graphs repeat explicitly and transition guards are typed',
    () {
      final library = GameRuleLibrary();
      final graph = GameRuleGraph(
        root: 'act',
        nodes: [
          GameRuleNode.action(
            'act',
            'game.credit-objective',
            arguments: {'objective': 'goal', 'count': 1},
          ),
        ],
      );
      final definition = GameStateMachineDefinition(
        initial: 'idle',
        states: {
          'idle': GameRuleDefinition(graph: graph),
          'done': GameRuleDefinition(graph: graph, repeat: false),
        },
        transitions: [
          GameStateTransition(
            from: 'idle',
            to: 'done',
            predicate: 'game.objective-complete',
            arguments: {'objective': 'goal'},
          ),
        ],
      );
      final entities = GameEntityTable(), facts = _Facts();
      final actor = entities.spawn('actor');
      final machine = GameStateMachineDefinition.fromJson(definition.toJson())
          .instantiate(
            actor: actor,
            epoch: 1,
            actions: library.actions,
            predicates: library.predicates,
            services: {'game.facts': facts},
          );
      for (var tick = 1; tick <= 2; tick++) {
        machine.step(tick: tick, epoch: 1, entities: entities);
        expect(machine.drainCommands(), hasLength(1));
      }
      facts.done = true;
      machine.step(tick: 3, epoch: 1, entities: entities);
      expect(machine.state, 'done');
      expect(machine.drainCommands(), hasLength(1));
      machine.step(tick: 4, epoch: 1, entities: entities);
      expect(machine.drainCommands(), isEmpty);
      machine.close();
      final restored =
          GameStateMachineDefinition(
            initial: 'done',
            states: definition.states,
            transitions: definition.transitions,
          ).instantiate(
            actor: actor,
            epoch: 2,
            actions: library.actions,
            predicates: library.predicates,
            services: {'game.facts': facts},
          );
      restored.restoreTerminalStatus(BehaviorStatus.succeeded);
      expect(
        restored.step(tick: 5, epoch: 2, entities: entities),
        BehaviorStatus.succeeded,
      );
      expect(restored.drainCommands(), isEmpty);
      expect(
        () => restored.restoreTerminalStatus(BehaviorStatus.failed),
        throwsStateError,
      );
      restored.close();
      expect(
        () => GameStateMachineDefinition(
          initial: 'idle',
          states: definition.states,
          transitions: [
            GameStateTransition(
              from: 'idle',
              to: 'done',
              predicate: 'game.has-item',
              arguments: {'item': 'key', 'count': 'one'},
            ),
          ],
        ).validate(library.actions, library.predicates),
        throwsFormatException,
      );
    },
  );
  test('authored physics bounds reject invalid or unconsumed shape fields', () {
    final value = GameColliderDefinition(
      shape: GameColliderShape.box,
      motion: GameBodyMotion.dynamic,
      halfExtents: const Vec3(1, .5, 2),
    );
    expect(GameColliderDefinition.fromJson(value.toJson()).halfExtents.z, 2);
    expect(() => GameColliderDefinition(radius: -1), throwsArgumentError);
    expect(() => GameColliderDefinition(mass: double.nan), throwsArgumentError);
  });
  test(
    'level component codecs retain entity references through spawn recipes',
    () {
      final registry = GameRegistry();
      registerGameLevelCodecs(registry);
      final template = GameSpawnTemplate(
        id: 'checkpoint',
        registry: registry,
        entities: [
          GameEntityRecord(id: 'spawn'),
          GameEntityRecord(
            id: 'marker',
            components: [
              GameComponentRecord('game.checkpoint', 1, {
                'spawn': 'spawn',
                'radius': 2.0,
              }),
            ],
          ),
        ],
      );
      expect(
        template.instantiate('one')[1].components.single.data['spawn'],
        'one/spawn',
      );
      expect(
        () => registry.construct(
          GameComponentRecord('game.checkpoint', 1, {
            'spawn': 'spawn',
            'radius': -1,
          }),
        ),
        throwsArgumentError,
      );
    },
  );
}

class _Facts implements GameRuleFacts {
  bool done = false;
  @override
  bool hasItem(GameEntityHandle actor, String item, int count) => false;
  @override
  bool interactionApplied(GameEntityHandle actor, String interaction) => false;
  @override
  bool objectiveComplete(GameEntityHandle actor, String objective) => done;
}
