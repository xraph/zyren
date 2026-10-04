import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game/authored.dart';
import 'session_test.dart' show recipe, Probe;

class CheckpointWorld implements GameAuthoredWorld, GameCheckpointFacts {
  int respawns = 0;
  final changed = <String>[];
  @override
  bool checkpointActive(GameEntityHandle actor, String checkpoint) =>
      checkpoint == 'checkpoint';
  @override
  bool respawnActor(GameEntityHandle actor) {
    respawns++;
    return true;
  }

  @override
  bool inReach(GameEntityHandle actor, GameEntityHandle target) => true;
  @override
  bool within(GameEntityHandle actor, String target, double distance) => false;
  @override
  bool controlling(GameEntityHandle actor, String target) => false;
  @override
  bool possess(GameEntityHandle actor, GameEntityHandle target) => false;
  @override
  bool setActive(GameEntityHandle actor, GameEntityHandle target, bool active) {
    changed.add(actor.id);
    return true;
  }
}

void main() {
  test(
    'actor cancellation removes due and future work while preserving other actors',
    () async {
      final seen = <Object>[];
      late GameEntityHandle actor, other;
      final session = GameSession(
        project: recipe(),
        seed: 1,
        systems: [
          Probe(
            'cancel',
            GamePhase.rules,
            [],
            update: (s) {
              if (s.tick == 2) expect(s.cancelCommands(actor), 2);
            },
          ),
          Probe(
            'observe',
            GamePhase.sensors,
            [],
            update: (s) {
              seen.addAll(s.currentCommands.map((c) => c.payload));
            },
          ),
        ],
      )..step();
      actor = session.entities.entities.single.handle;
      other = session.entities.spawn('other');
      session.commands.enqueue(
        GameCommand(actor, 2, 'actor-due'),
        session.entities,
      );
      session.commands.enqueue(
        GameCommand(actor, 3, 'actor-future'),
        session.entities,
      );
      session.commands.enqueue(
        GameCommand(other, 2, 'other-due'),
        session.entities,
      );
      session.commands.enqueue(
        GameCommand(other, 3, 'other-future'),
        session.entities,
      );
      try {
        session.step();
        session.step();
        expect(seen, ['other-due', 'other-future']);
        expect(session.fault, isNull);
        expect(session.entities.isAlive(actor), isTrue);
      } finally {
        await session.close();
      }
    },
  );
  test(
    'typed checkpoint predicate and respawn cancel only that actor while preserving inventory',
    () async {
      final library = GameRuleLibrary(), registry = GameRegistry();
      registerGameComponentCodecs(registry);
      registry.registerComponent(
        GameRuleComponentCodec(library.actions, library.predicates),
      );
      final world = CheckpointWorld(),
          gameplay = GameAuthoredGameplay(library: library, world: world);
      final session = GameSession(
        project: CompiledGameProject(
          project: GameProject(
            id: 'checkpoint-rules',
            startupLevel: 'main',
            registry: registry,
            levels: [
              GameLevel(
                id: 'main',
                scene: GameSceneIdentity('scene', 'pin'),
                entities: [
                  GameEntityRecord(
                    id: 'actor',
                    components: [
                      GameComponentRecord(
                        'game.inventory',
                        1,
                        Inventory(capacity: 5, items: {'key': 1}).toJson(),
                      ),
                      GameComponentRecord(
                        'game.rules',
                        1,
                        GameRuleDefinition(
                          repeat: false,
                          graph: GameRuleGraph(
                            root: 'flow',
                            nodes: [
                              GameRuleNode.sequence('flow', [
                                'checkpoint',
                                'respawn',
                                'old-command',
                              ]),
                              GameRuleNode.predicate(
                                'checkpoint',
                                'game.checkpoint-active',
                                arguments: {'target': 'checkpoint'},
                              ),
                              GameRuleNode.action('respawn', 'game.respawn'),
                              GameRuleNode.action(
                                'old-command',
                                'game.set-active',
                                arguments: {
                                  'target': 'checkpoint',
                                  'active': false,
                                },
                              ),
                            ],
                          ),
                        ).toJson(),
                      ),
                    ],
                  ),
                  GameEntityRecord(
                    id: 'other',
                    components: [
                      GameComponentRecord(
                        'game.rules',
                        1,
                        GameRuleDefinition(
                          repeat: false,
                          graph: GameRuleGraph(
                            root: 'fresh',
                            nodes: [
                              GameRuleNode.action(
                                'fresh',
                                'game.set-active',
                                arguments: {
                                  'target': 'checkpoint',
                                  'active': false,
                                },
                              ),
                            ],
                          ),
                        ).toJson(),
                      ),
                    ],
                  ),
                  GameEntityRecord(id: 'checkpoint'),
                ],
              ),
            ],
          ),
        ),
        seed: 1,
        systems: [gameplay],
      );
      try {
        session.step();
        session.step();
        session.step();
        expect(world.respawns, 1);
        expect(world.changed, ['other']);
        final actor = session.entities.entities
            .singleWhere((e) => e.handle.id == 'actor')
            .handle;
        expect(gameplay.hasItem(actor, 'key', 1), isTrue);
        expect(session.fault, isNull);
      } finally {
        await session.close();
      }
    },
  );
}
