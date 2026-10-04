part of '../../zyren_game_ai.dart';

/// Shared permitted perception and bounded historical messages for native teams.
abstract final class TrainingMultiProfiles {
  static TrainingMultiProfile forTask({required String task}) {
    if (!['cooperative-search', 'competitive-pursuit'].contains(task)) {
      throw ArgumentError('Unknown native team task.');
    }
    return TrainingMultiProfile._(task);
  }

  static TrainingMultiProfile fromJson(Map<String, Object?> header) {
    final task = header['task'];
    if (task is! String) throw const FormatException('Team task is missing.');
    final profile = forTask(task: task);
    if (_multiHeaderHash(header) != profile.configurationHash) {
      throw const FormatException('Native team profile differs.');
    }
    return profile;
  }
}

final class TrainingMultiProfile {
  final String task;
  TrainingMultiProfile._(this.task);
  String get artifactFamily => task;
  int get fixedHz => 50;
  int get maxHoldTicks => 2;
  int get messageCadenceTicks => 5;
  String get messageTarget =>
      task == 'cooperative-search' ? 'authored-goal-visible-handle' : 'none';
  Map<String, String> get roleNames => Map.unmodifiable(
    task == 'cooperative-search'
        ? {'positive': 'scout', 'negative': 'searcher'}
        : {'positive': 'pursuer', 'negative': 'evader'},
  );
  bool get jumpRequiresGrounded => true;
  bool get interactionEnabled => false;
  SensorProfile get perception => SensorProfile(
    range: 15,
    halfAngleRadians: math.pi,
    maxEntities: 3,
    maxCandidates: 3,
    queryBudget: 12,
    materials: {SensorMaterial.unknown: SensorMaterialRule.block},
  );
  CommunicationProfile get communication => CommunicationProfile(
    delayTicks: 2,
    ttlTicks: 100,
    maxPending: 8,
    maxEventIds: 256,
    maxMessagesPerActor: 1,
    range: 15,
  );
  ObservationAssembler get assembler => ObservationAssembler(
    registry: SensorRegistry()
      ..register(BodySensor(maxSpeed: 10))
      ..register(VisionSensor(perception)),
    profile: perception,
  );
  ActionDecoder get decoder => ActionDecoder.characterDiscrete();
  String get configurationHash => _multiHeaderHash(toJson());
  ObservationSpec get spec => ObservationSpec(
    id: '$task-v2',
    configurationHash: configurationHash,
    fields: [
      ...assembler.spec.fields,
      ObservationField('registered-role', min: -1, max: 1),
      ObservationField(
        'registered-route-world-xz',
        width: 2,
        min: -10000,
        max: 10000,
      ),
      ObservationField('registered-route-valid', min: 0, max: 1),
      ObservationField(
        'historical-team-position-local',
        width: 3,
        min: -10000,
        max: 10000,
      ),
      ObservationField('historical-team-age', min: 0, max: 1),
      ObservationField('historical-team-validity', width: 2, min: 0, max: 1),
    ],
    maxEntities: 3,
    maxRays: 0,
    range: 15,
    cadenceTicks: 1,
    latencyTicks: 1,
  );
  Map<String, Object?> toJson() => {
    'version': 2,
    'role_names': roleNames,
    'message_cadence_ticks': messageCadenceTicks,
    'message_target': messageTarget,
    'masks': {'jump': 'grounded-only', 'interact': interactionEnabled},
    'task': task,
    'perception': assembler.spec.toJson(),
    'communication': communication.toJson(),
    'fixed_hz': fixedHz,
    'max_hold_ticks': maxHoldTicks,
    'route': 'authored-waypoint-world-xz-divided-by-range',
    'historical_message': 'captured-sender-local-rebased-with-captured-pose',
    'message_position': 'recipient-local-divided-by-range',
    'message_age': 'observed-tick-age-divided-by-ttl',
    'actor_input_exclusions': ['state', 'teacher_actions', 'distances'],
  };
}

String _multiHeaderHash(Object? value) {
  Object? sorted(Object? v) => v is Map
      ? {
          for (final key in (v.keys.cast<String>().toList()..sort()))
            key: sorted(v[key]),
        }
      : v is List
      ? v.map(sorted).toList()
      : v;
  return _hash(sorted(value)!);
}
