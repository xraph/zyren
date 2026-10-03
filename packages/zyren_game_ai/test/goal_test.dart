import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'memory_test.dart' show identity;

BrainContext context(
  int tick,
  List<GameGoal> goals, {
  Set<GameEntityHandle> validTargets = const {},
}) => BrainContext(
  identity: identity('guard'),
  tick: tick,
  beliefs: const [],
  goals: goals,
  validTargets: validTargets,
  actionSpec: ScriptedBrain.characterActions,
);
void main() {
  test(
    'utility uses deterministic priorities and minimum commitment without oscillation',
    () {
      final selector = UtilityGoalSelector(minCommitmentTicks: 5);
      final patrol = GameGoal(
        id: 'patrol',
        skill: 'follow-route',
        priority: 1,
        utility: .5,
      );
      final sound = GameGoal(
        id: 'sound',
        skill: 'investigate',
        priority: 1,
        utility: .8,
      );
      expect(selector.choose(context(1, [patrol])), patrol);
      expect(selector.choose(context(2, [patrol, sound])), patrol);
      expect(selector.choose(context(6, [patrol, sound])), sound);
      expect(selector.choose(context(7, [patrol])), patrol);
    },
  );
  test(
    'a despawned target cannot keep a goal or match a replacement generation',
    () {
      final old = GameEntityHandle('runner', 1),
          replacement = GameEntityHandle('runner', 2);
      final goal = GameGoal(
        id: 'chase',
        skill: 'investigate',
        target: old,
        priority: 10,
      );
      final selector = UtilityGoalSelector(minCommitmentTicks: 10);
      expect(selector.choose(context(1, [goal], validTargets: {old})), goal);
      expect(
        selector.choose(context(2, [goal], validTargets: {replacement})),
        isNull,
      );
    },
  );
  test(
    'utility ties sort by goal id and bounded configuration rejects nonfinite scores',
    () {
      final selector = UtilityGoalSelector();
      final z = GameGoal(id: 'z', skill: 'idle'),
          a = GameGoal(id: 'a', skill: 'idle');
      expect(selector.choose(context(1, [z, a])), a);
      expect(
        () => GameGoal(id: 'bad', skill: 'idle', utility: double.nan),
        throwsArgumentError,
      );
      expect(
        () => UtilityGoalSelector(minCommitmentTicks: -1),
        throwsRangeError,
      );
    },
  );
}
