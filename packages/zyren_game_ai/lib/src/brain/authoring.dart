part of '../../zyren_game_ai.dart';

final class GameAiAuthoringDefinition {
  final String profile, brain;
  final String? modelHash, cameraMode;
  final String? multiTask, teamId, multiRole, goalEntityId;
  final List<Vec3> authoredRoute;
  GameAiAuthoringDefinition(Map<String, Object?> data)
    : profile = data['profile'] as String,
      brain = data['brain'] as String,
      modelHash = data['modelHash'] as String?,
      cameraMode = data['cameraMode'] as String?,
      multiTask = data['multiTask'] as String?,
      teamId = data['teamId'] as String?,
      multiRole = data['multiRole'] as String?,
      goalEntityId = data['goalEntityId'] as String?,
      authoredRoute = _authoredRoute(data['authoredRoute']) {
    if (!['guard', 'vehicle'].contains(profile) ||
        !['scripted', 'learned', 'hybrid'].contains(brain) ||
        cameraMode != null &&
            !['rgb', 'depth', 'combined'].contains(cameraMode) ||
        modelHash != null && !RegExp(r'^[0-9a-f]{64}$').hasMatch(modelHash!)) {
      throw ArgumentError('Invalid AI profile or model pin.');
    }
    if (multiTask == null) {
      if (teamId != null ||
          multiRole != null ||
          goalEntityId != null ||
          authoredRoute.isNotEmpty) {
        throw ArgumentError('Team metadata requires a multi-agent task.');
      }
    } else {
      final cooperative = multiTask == 'cooperative-search';
      if (!['cooperative-search', 'competitive-pursuit'].contains(multiTask) ||
          profile != 'guard' ||
          cameraMode != null ||
          teamId == null ||
          cooperative != (goalEntityId != null)) {
        throw ArgumentError('Invalid multi-agent task, role or goal binding.');
      }
      if (!TrainingMultiProfiles.forTask(
        task: multiTask!,
      ).roleNames.values.contains(multiRole)) {
        throw ArgumentError('Invalid registered multi-agent role.');
      }
      _name(teamId!);
      if (goalEntityId != null) {
        try {
          GameLocalReference(['goalEntityId'], goalEntityId!);
        } on FormatException {
          throw ArgumentError('Invalid authored goal entity.');
        }
      }
    }
    if (brain != 'scripted' && modelHash == null) {
      throw ArgumentError('Learned and hybrid brains require a model pin.');
    }
  }
  TrainingMultiProfile? get multiProfile => multiTask == null
      ? null
      : TrainingMultiProfiles.forTask(task: multiTask!);
  int? get registeredRole {
    final profile = multiProfile;
    if (profile == null) return null;
    return profile.roleNames['positive'] == multiRole ? 1 : -1;
  }

  TrainingVisualProfile? get visualProfile => cameraMode == null
      ? null
      : TrainingVisualProfiles.forFamily(family: profile, mode: cameraMode!);
  ObservationSpec get observationSpec =>
      multiProfile?.spec ?? visualProfile?.spec ?? createSensors().spec;
  String get artifactFamily =>
      multiProfile?.artifactFamily ?? visualProfile?.artifactFamily ?? profile;

  /// Structured sensors remain available to the scripted baseline. Visual
  /// learned input uses [visualProfile] and its separate observation schema.
  ObservationAssembler createSensors() =>
      multiProfile?.assembler ??
      (profile == 'guard'
          ? TrainingProfiles.guard()
          : TrainingProfiles.vehicle());
  ActionDecoder createActions() =>
      multiProfile?.decoder ??
      (profile == 'guard'
          ? ActionDecoder.characterDiscrete()
          : ActionDecoder.vehiclePedals());
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
  Iterable<GameLocalReference> localReferences(Map<String, Object?> data) {
    final definition = GameAiAuthoringDefinition(data);
    return definition.goalEntityId == null
        ? const []
        : [
            GameLocalReference(['goalEntityId'], definition.goalEntityId!),
          ];
  }

  @override
  GameAiAuthoringDefinition factory(Map<String, Object?> data) =>
      GameAiAuthoringDefinition(data);
}

void registerGameAiCodecs(GameRegistry registry) {
  registry.registerComponent(GameAiAuthoringCodec());
}

List<Vec3> _authoredRoute(Object? value) {
  if (value == null) return const [];
  if (value is! List || value.length > 32) {
    throw ArgumentError('Authored route exceeds 32 waypoints.');
  }
  return List<Vec3>.unmodifiable(
    value.map((point) {
      if (point is! List ||
          point.length != 3 ||
          point.any((v) => v is! num || !v.isFinite || v.abs() > 100000)) {
        throw ArgumentError('Invalid authored route waypoint.');
      }
      return Vec3(
        (point[0] as num).toDouble(),
        (point[1] as num).toDouble(),
        (point[2] as num).toDouble(),
      );
    }),
  );
}
