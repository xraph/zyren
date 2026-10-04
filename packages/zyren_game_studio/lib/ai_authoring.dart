/// Pure authoring catalog shared by Studio and offline game compilation.
library;

import 'dart:convert';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'authoring.dart';
import 'levels.dart';

/// Model resources are opaque Pipeline pins, separate from visual glTF assets.
Map<String, PipelineAssetReference> gameAiModelReferences(
  GameAuthoring authoring,
  StudioDocument document, {
  bool includeScripted = false,
}) {
  final result = <String, PipelineAssetReference>{};
  if (!document.extensions.containsKey('zyren.game')) return result;
  for (final entity in authoring.expanded(document).entities) {
    for (final component in entity.components.where(
      (c) => c.type == 'game.ai',
    )) {
      final definition = GameAiAuthoringDefinition(component.data);
      if (definition.brain == 'scripted' && !includeScripted) continue;
      final value = component.data['modelReference'];
      if (definition.brain == 'scripted' && value == null) continue;
      if (value is! Map ||
          value.length != 6 ||
          jsonEncode(value).length > 4096) {
        throw StateError('${entity.id} needs a bounded model asset reference.');
      }
      final pin = PipelineAssetReference.fromJson(
        Map<String, Object?>.from(value),
      );
      if (pin.sha256 != definition.modelHash ||
          pin.sourceId != 'model.${pin.sha256}.actor.onnx') {
        throw StateError(
          'Authored model reference differs from its model SHA.',
        );
      }
      final previous = result[pin.sha256];
      if (previous != null && previous.encode() != pin.encode()) {
        throw StateError('The same model has conflicting asset references.');
      }
      result[pin.sha256] = pin;
      if (result.length > 8) {
        throw StateError('The editor supports eight models.');
      }
    }
  }
  return Map.unmodifiable(result);
}

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
          GameFieldDescriptor(
            'modelReference',
            'Pinned model resource',
            GameFieldKind.json,
            required: false,
          ),
        ],
      ),
    ],
  );
}
