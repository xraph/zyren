part of '../../zyren_game_ai.dart';

/// The same schemas and mappings serve demonstrations, training and deployment.
abstract final class TrainingActions {
  static const movementBins = [-1.0, -.5, 0.0, .5, 1.0];
  static const pitchBins = [-1.0, 0.0, 1.0];
  static ActionSpec get character => ActionSpec(
    id: 'character-discrete-v1',
    branches: [
      for (final name in ['moveX', 'moveZ', 'yaw'])
        ActionBranch(
          name,
          choices: [
            'negative',
            'half-negative',
            'zero',
            'half-positive',
            'positive',
          ],
        ),
      ActionBranch('pitch', choices: ['negative', 'zero', 'positive']),
      ActionBranch('jump', choices: ['stay', 'jump']),
      ActionBranch('interact', choices: ['stay', 'interact']),
    ],
    fallbackDiscrete: [2, 2, 2, 1, 0, 0],
  );
  static ActionSpec get vehicle => ActionSpec(
    id: 'vehicle-pedals-v1',
    continuous: [
      ObservationField('steer'),
      ObservationField('throttle', min: 0, max: 1),
      ObservationField('brake', min: 0, max: 1),
    ],
    fallbackContinuous: [0, 0, 1],
  );
  static PolicyAction encodeCharacter(CharacterIntent intent) {
    intent.validate();
    int closest(List<double> values, double value) {
      var best = 0;
      for (var i = 1; i < values.length; i++) {
        if ((values[i] - value).abs() < (values[best] - value).abs()) best = i;
      }
      return best;
    }

    return PolicyAction([], [
      closest(movementBins, intent.moveX),
      closest(movementBins, intent.moveZ),
      closest(movementBins, intent.lookYaw / math.pi),
      closest(pitchBins, intent.lookPitch / (math.pi / 2)),
      intent.jump ? 1 : 0,
      intent.interact ? 1 : 0,
    ]);
  }

  static PolicyAction encodeVehicle(VehicleIntent intent) {
    intent.validate();
    return PolicyAction([
      intent.steer,
      intent.brake > 0 ? 0 : intent.throttle,
      intent.brake,
    ], []);
  }
}

/// Public structured sensor bindings shared by native training and game hosts.
abstract final class TrainingProfiles {
  static SensorProfile guardProfile() => SensorProfile(
    materials: {SensorMaterial.unknown: SensorMaterialRule.block},
    range: 15,
    halfAngleRadians: math.pi,
    maxEntities: 1,
    maxCandidates: 1,
    queryBudget: 4,
  );
  static ObservationAssembler guard() {
    final profile = guardProfile();
    return ObservationAssembler(
      registry: SensorRegistry()
        ..register(BodySensor(maxSpeed: 10))
        ..register(VisionSensor(profile)),
      profile: profile,
    );
  }

  static SensorProfile vehicleProfile() => SensorProfile(
    range: 20,
    maxEntities: 1,
    maxCandidates: 1,
    queryBudget: 4,
    materials: {SensorMaterial.unknown: SensorMaterialRule.block},
  );
  static ObservationAssembler vehicle() {
    final profile = vehicleProfile();
    return ObservationAssembler(
      registry: SensorRegistry()
        ..register(BodySensor(maxSpeed: 30))
        ..register(RaySensor(profile, directions: [const Vec3(0, 0, 1)])),
      profile: profile,
    );
  }
}
