import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  final discrete = ActionDecoder.characterDiscrete().spec;
  final mask = [
    for (final branch in discrete.branches)
      List<bool>.filled(branch.choices.length, true),
  ];
  test(
    'hybrid scripted fallback does not inherit discrete policy masks',
    () async {
      final entities = GameEntityTable();
      final id = BrainIdentity(
        episodeId: 'test',
        entity: entities.spawn('npc'),
        modelHash: 'script',
      );
      final scripted = ScriptedBrain(identity: id, entities: entities);
      final hybrid = HybridBrain(
        identity: id,
        selector: UtilityGoalSelector(),
        skills: {'idle': scripted},
        actionSpecs: {'idle': scripted.actionSpec},
      );
      addTearDown(hybrid.close);
      final decision = hybrid.decide(
        BrainContext(
          identity: id,
          tick: 1,
          beliefs: [],
          goals: [GameGoal(id: 'idle', skill: 'idle')],
          actionSpec: discrete,
          legality: mask,
        ),
      );
      expect(decision.actions.single.action, 'ai.move');
      expect(hybrid.activeSkill, 'idle');
    },
  );
  test('foreign discrete mask rejects before activating a skill', () async {
    final entities = GameEntityTable();
    final id = BrainIdentity(
      episodeId: 'test',
      entity: entities.spawn('npc'),
      modelHash: 'script',
    );
    final scripted = ScriptedBrain(identity: id, entities: entities);
    final other = ActionSpec(
      id: 'different-schema',
      branches: discrete.branches,
      fallbackDiscrete: discrete.fallbackDiscrete,
    );
    final hybrid = HybridBrain(
      identity: id,
      selector: UtilityGoalSelector(),
      skills: {'idle': scripted},
      actionSpecs: {'idle': other},
    );
    addTearDown(hybrid.close);
    expect(
      () => hybrid.decide(
        BrainContext(
          identity: id,
          tick: 1,
          beliefs: [],
          goals: [GameGoal(id: 'idle', skill: 'idle')],
          actionSpec: discrete,
          legality: mask,
        ),
      ),
      throwsArgumentError,
    );
    expect(hybrid.activeSkill, isNull);
  });
}
