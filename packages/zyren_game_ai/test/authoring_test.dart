import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
void main() {
  test('standalone registry decodes the same AI pins and exact training bindings', () {
    final registry = GameRegistry(); registerGameAiCodecs(registry);
    for (final profile in ['guard', 'vehicle']) {
      final definition = registry.construct(GameComponentRecord('game.ai', 1, {'profile': profile, 'brain': 'scripted'})) as GameAiAuthoringDefinition;
      expect(definition.createSensors().spec.hash, (profile == 'guard' ? TrainingProfiles.guard() : TrainingProfiles.vehicle()).spec.hash);
      expect(definition.createActions().spec.hash, (profile == 'guard' ? ActionDecoder.characterDiscrete() : ActionDecoder.vehiclePedals()).spec.hash);
    }
  });
  test('learned authoring requires model SHA and unknown profile is rejected', () {
    final registry = GameRegistry(); registerGameAiCodecs(registry);
    expect(() => registry.construct(GameComponentRecord('game.ai', 1, {'profile': 'guard', 'brain': 'learned'})), throwsArgumentError);
    expect(() => registry.construct(GameComponentRecord('game.ai', 1, {'profile': 'omniscient', 'brain': 'scripted'})), throwsArgumentError);
    final pinned = registry.construct(GameComponentRecord('game.ai', 1, {'profile': 'vehicle', 'brain': 'hybrid', 'modelHash': 'a' * 64})) as GameAiAuthoringDefinition;
    expect(pinned.modelHash, 'a' * 64);
  });
}
