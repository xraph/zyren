import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  test(
    'camera mode is optional and preserves the controller and structured default',
    () {
      final registry = GameRegistry();
      registerGameAiCodecs(registry);
      for (final family in ['guard', 'vehicle']) {
        GameAiAuthoringDefinition decode([String? mode]) =>
            registry.construct(
                  GameComponentRecord('game.ai', 1, {
                    'profile': family,
                    'brain': 'scripted',
                    'cameraMode': ?mode,
                  }),
                )
                as GameAiAuthoringDefinition;
        final original = decode();
        expect(original.cameraMode, isNull);
        expect(original.visualProfile, isNull);
        expect(
          original.observationSpec.hash,
          original.createSensors().spec.hash,
        );
        expect(original.artifactFamily, family);
        for (final mode in ['rgb', 'depth', 'combined']) {
          final definition = decode(mode);
          expect(definition.profile, family);
          expect(definition.cameraMode, mode);
          expect(definition.artifactFamily, '$family-visual-$mode');
          expect(
            definition.observationSpec.hash,
            TrainingVisualProfiles.forFamily(
              family: family,
              mode: mode,
            ).spec.hash,
          );
          expect(
            definition.createActions().spec.hash,
            original.createActions().spec.hash,
          );
        }
        expect(() => decode('labels'), throwsArgumentError);
      }
    },
  );
}
