import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_studio/levels.dart';
import 'package:zyren_game_studio/compiler.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  test(
    'prefab state guards remap after duplication save and compilation',
    () async {
      final library = GameRuleLibrary();
      final authoring = createGameDevelopmentAuthoring(rules: library);
      final machines = GameStateMachineAuthoring(authoring, library);
      var document = StudioDocument(
        id: 'guards',
        title: 'Guards',
        nodes: [StudioNode(id: 'actor', label: 'Actor')],
      );
      final empty = GameRuleDefinition(
        graph: GameRuleGraph(
          root: 'root',
          nodes: [GameRuleNode.sequence('root', [])],
        ),
      );
      document = machines.replace(
        document,
        'actor',
        GameStateMachineDefinition(
          initial: 'idle',
          states: {'idle': empty},
          transitions: [
            GameStateTransition(
              from: 'idle',
              to: 'idle',
              predicate: 'game.within',
              arguments: {'target': 'actor', 'distance': 2.0},
            ),
            GameStateTransition(
              from: 'idle',
              to: 'idle',
              predicate: 'game.is-controlling',
              arguments: {'target': 'actor'},
            ),
          ],
        ),
      );
      document = authoring.createPrefab(document, 'actor', prefabId: 'guard');
      document = authoring.duplicate(document, 'actor', newId: 'second');
      document = StudioDocument.decode(document.encode());
      final compiled =
          await GameProjectCompiler(
            registry: authoring.registry,
            assets: PipelineAssetLibrary(readBundle: (_, _) async => null),
          ).compile(
            documents: [document],
            startupLevel: authoring.expanded(document).levelId,
            profile: GameBuildProfile(id: 'native'),
          );
      expect(
        compiled.status,
        GameBuildStatus.ready,
        reason: compiled.diagnostics.join('\n'),
      );
      final entities =
          compiled.artifact!.project.project.levels.single.entities;
      expect(entities, hasLength(2));
      for (final entity in entities) {
        final state = GameStateMachineDefinition.fromJson(
          entity.components.single.data,
        );
        expect(
          state.transitions.map((t) => t.arguments['target']),
          everyElement(entity.id),
        );
      }
    },
  );
  test('states preserve compiled graphs, references and one-step undo', () {
    final library = GameRuleLibrary(),
        authoring = createGameDevelopmentAuthoring();
    final machines = GameStateMachineAuthoring(authoring, library);
    var document = GameTemplate(
      GameTemplateKind.exploration,
      authoring,
    ).create(projectId: 'states').document;
    final empty = GameRuleDefinition(
      graph: GameRuleGraph(
        root: 'root',
        nodes: [GameRuleNode.sequence('root', [])],
      ),
    );
    document = machines.replace(
      document,
      'player',
      GameStateMachineDefinition(
        initial: 'idle',
        states: {'idle': empty},
        transitions: [],
      ),
    );
    document = machines.addState(document, 'player', 'drive');
    final rules = GameRuleAuthoring(authoring, library, state: 'drive');
    document = rules.appendChild(
      document,
      'player',
      'root',
      GameRuleNode.action(
        'collect',
        'game.collect-item',
        arguments: {'source': 'key', 'item': 'key', 'count': 1},
      ),
    );
    document = rules.invert(document, 'player', 'collect');
    expect(
      rules.read(document, 'player').graph.nodes.last.kind,
      GameRuleKind.inverter,
    );
    document = rules.invert(document, 'player', 'invert-1');
    expect(rules.read(document, 'player').graph.nodes.map((n) => n.id), [
      'root',
      'collect',
    ]);
    final machine = machines.read(document, 'player');
    document = machines.replace(
      document,
      'player',
      GameStateMachineDefinition(
        initial: machine.initial,
        states: machine.states,
        transitions: [
          GameStateTransition(
            from: 'idle',
            to: 'drive',
            predicate: 'game.has-item',
            arguments: {'item': 'key', 'count': 1},
          ),
        ],
      ),
    );
    final scene = StudioScene(document);
    scene.apply(machines.removeState(document, 'player', 'drive'));
    expect(machines.read(scene.document, 'player').transitions, isEmpty);
    scene.undo();
    expect(scene.document.encode(), document.encode());
    expect(
      authoring.validate(StudioDocument.decode(document.encode())),
      isEmpty,
    );
    expect(
      () => machines.removeState(document, 'player', 'idle'),
      throwsArgumentError,
    );
  });
  test(
    'rule edits validate typed ports and cycles before one shared history entry',
    () {
      final library = GameRuleLibrary();
      final authoring = createGameDevelopmentAuthoring(rules: library);
      final rules = GameRuleAuthoring(authoring, library);
      final source = GameTemplate(
        GameTemplateKind.exploration,
        authoring,
      ).create(projectId: 'rules').document;
      final scene = StudioScene(source);
      expect(
        () => rules.replaceNode(
          source,
          'player',
          GameRuleNode.action(
            'key-credit',
            'game.credit-objective',
            arguments: {'objective': 'key', 'count': 'one'},
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => rules.replaceNode(
          source,
          'player',
          GameRuleNode.selector('root', ['root']),
        ),
        throwsFormatException,
      );
      final next = rules.removeSubtree(source, 'player', 'credit-gate');
      scene.apply(next);
      expect(
        rules.read(next, 'player').graph.nodes.any((n) => n.id == 'gate-open'),
        isFalse,
      );
      scene.undo();
      expect(scene.document.encode(), source.encode());
    },
  );
  test(
    'input bindings and checkpoint references remain persisted and checked',
    () {
      final authoring = createGameDevelopmentAuthoring();
      final source = GameTemplate(
        GameTemplateKind.vehiclePlayground,
        authoring,
      ).create(projectId: 'bindings').document;
      final next = authoring.setFields(
        source,
        nodeId: 'player',
        component: 'game.input',
        fields: {
          'bindings': [
            {'control': 'ArrowUp', 'action': 'move.z', 'scale': 1},
          ],
        },
      );
      final reload = StudioDocument.decode(next.encode());
      expect(
        authoring
            .entityFor(reload, 'player')!
            .components
            .singleWhere((c) => c.type == 'game.input')
            .data['bindings'],
        [
          {'control': 'ArrowUp', 'action': 'move.z', 'scale': 1},
        ],
      );
      expect(
        () => GameLevelAuthoring(
          authoring,
        ).checkpoint(reload, 'checkpoint', spawnEntity: 'missing'),
        throwsA(anything),
      );
    },
  );
}
