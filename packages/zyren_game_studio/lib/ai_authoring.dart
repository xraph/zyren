/// Pure authoring catalog shared by Studio and offline game compilation.
library;

import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'authoring.dart';
import 'levels.dart';

/// Compose the established catalog, including imported character rigs.
GameAuthoring createGameAiDevelopmentAuthoring({GameRuleLibrary? rules}) {
  final registry = GameRegistry();
  registerGameAiCodecs(registry);
  final base = createGameDevelopmentAuthoring(rules: rules, registry: registry);
  return GameAuthoring(
    registry,
    descriptors: [
      ...base.descriptors.values,
      GameComponentDescriptor(
        type: 'game.ai',
        label: 'NPC policy and perception',
        defaults: const {'profile': 'guard', 'brain': 'scripted'},
        fields: const [
          GameFieldDescriptor(
            'profile',
            'Sensor/action profile',
            GameFieldKind.choice,
            choices: ['guard', 'vehicle'],
          ),
          GameFieldDescriptor(
            'brain',
            'Brain mode',
            GameFieldKind.choice,
            choices: ['scripted', 'learned', 'hybrid'],
          ),
          GameFieldDescriptor(
            'modelHash',
            'Pinned evaluated model SHA256',
            GameFieldKind.text,
            required: false,
          ),
        ],
      ),
    ],
  );
}
