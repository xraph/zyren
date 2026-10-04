part of '../../zyren_game_ai.dart';

final class GameAiAuthoringDefinition {
  final String profile, brain;
  final String? modelHash, cameraMode;
  GameAiAuthoringDefinition(Map<String, Object?> data)
    : profile = data['profile'] as String,
      brain = data['brain'] as String,
      modelHash = data['modelHash'] as String?,
      cameraMode = data['cameraMode'] as String? {
    if (!['guard', 'vehicle'].contains(profile) ||
        !['scripted', 'learned', 'hybrid'].contains(brain) ||
        cameraMode != null &&
            !['rgb', 'depth', 'combined'].contains(cameraMode) ||
        modelHash != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(modelHash!)) {
      throw ArgumentError('Invalid AI profile or model pin.');
    }
    if (brain != 'scripted' && modelHash == null) {
      throw ArgumentError('Learned and hybrid brains require a model pin.');
    }
  }
  TrainingVisualProfile? get visualProfile => cameraMode == null
      ? null
      : TrainingVisualProfiles.forFamily(family: profile, mode: cameraMode!);
  ObservationSpec get observationSpec =>
      visualProfile?.spec ?? createSensors().spec;
  String get artifactFamily => visualProfile?.artifactFamily ?? profile;

  /// Structured sensors remain available to the scripted baseline. Visual
  /// learned input uses [visualProfile] and its separate observation schema.
  ObservationAssembler createSensors() => profile == 'guard'
      ? TrainingProfiles.guard()
      : TrainingProfiles.vehicle();
  ActionDecoder createActions() => profile == 'guard'
      ? ActionDecoder.characterDiscrete()
      : ActionDecoder.vehiclePedals();
}

final class GameAiAuthoringCodec
    extends GameComponentCodec<GameAiAuthoringDefinition> {
  @override
  String get type => 'game.ai';
  @override
  int get version => 1;
  @override
  void validate(Map<String, Object?> data) {
    GameAiAuthoringDefinition(data);
  }

  @override
  Map<String, Object?> migrate(int fromVersion, Map<String, Object?> data) {
    if (fromVersion != 1) {
      throw ArgumentError('AI component version unavailable.');
    }
    validate(data);
    return data;
  }

  @override
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data) =>
      const [];
  @override
  GameAiAuthoringDefinition factory(Map<String, Object?> data) =>
      GameAiAuthoringDefinition(data);
}

void registerGameAiCodecs(GameRegistry registry) {
  registry.registerComponent(GameAiAuthoringCodec());
}
