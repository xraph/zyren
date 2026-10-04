part of '../../zyren_game_ai.dart';

final class PolicyAction {
  final List<double> continuous;
  final List<int> discrete;
  PolicyAction(List<double> continuous, List<int> discrete)
    : continuous = List.unmodifiable(_sensorBoundedCopy(continuous, 128)),
      discrete = List.unmodifiable(_sensorBoundedCopy(discrete, 128));
}

final class DecodedAction {
  final PolicyAction action;
  final CharacterIntent? character;
  final VehicleIntent? vehicle;
  DecodedAction._(this.action, {this.character, this.vehicle});
}

/// Explicit normalized controller schemas. The motor owns speed and steering limits.
final class ActionDecoder {
  final ActionSpec spec;
  final bool driver, look, jump, discreteCharacter, pedals;
  final bool Function(PolicyAction)? _validateRecord;
  ActionDecoder._(
    this.spec, {
    this.driver = false,
    this.look = false,
    this.jump = false,
    this.discreteCharacter = false,
    this.pedals = false,
    bool Function(PolicyAction)? validateRecord,
  }) : _validateRecord = validateRecord;

  /// A pure validator admits a bounded domain record without a motor intent.
  /// Validation failures are rejected before recurrent state can commit.
  factory ActionDecoder.validatedRecord({
    required ActionSpec spec,
    required bool Function(PolicyAction) validate,
  }) {
    final decoder = ActionDecoder._(spec, validateRecord: validate);
    if (decoder.decode(
          PolicyAction(spec.fallbackContinuous, spec.fallbackDiscrete),
        ) ==
        null) {
      throw ArgumentError('Record fallback must pass domain validation.');
    }
    return decoder;
  }
  factory ActionDecoder.character({bool look = false, bool jump = false}) =>
      ActionDecoder._(
        ActionSpec(
          id: 'character-policy',
          continuous: [
            ObservationField('moveX'),
            ObservationField('moveZ'),
            if (look) ...[
              ObservationField('lookYaw'),
              ObservationField('lookPitch'),
            ],
          ],
          branches: [
            if (jump) ActionBranch('jump', choices: ['stay', 'jump']),
          ],
          fallbackContinuous: List.filled(look ? 4 : 2, 0),
          fallbackDiscrete: jump ? [0] : [],
        ),
        look: look,
        jump: jump,
      );
  factory ActionDecoder.vehicle() => ActionDecoder._(
    ActionSpec(
      id: 'vehicle-policy',
      continuous: [ObservationField('steering'), ObservationField('drive')],
      fallbackContinuous: [0, -1],
    ),
    driver: true,
  );
  factory ActionDecoder.characterDiscrete() =>
      ActionDecoder._(TrainingActions.character, discreteCharacter: true);
  factory ActionDecoder.vehiclePedals() =>
      ActionDecoder._(TrainingActions.vehicle, driver: true, pedals: true);
  DecodedAction get fallback =>
      decode(PolicyAction(spec.fallbackContinuous, spec.fallbackDiscrete))!;
  DecodedAction? decode(PolicyAction action, {List<List<bool>>? legality}) {
    if (!spec.accepts(action.continuous, action.discrete, legality: legality)) {
      return null;
    }
    final validate = _validateRecord;
    if (validate != null) {
      try {
        return validate(action) ? DecodedAction._(action) : null;
      } on Object {
        return null;
      }
    }
    final v = action.continuous;
    if (discreteCharacter) {
      final d = action.discrete;
      final intent = CharacterIntent(
        moveX: TrainingActions.movementBins[d[0]],
        moveZ: TrainingActions.movementBins[d[1]],
        lookYaw: TrainingActions.movementBins[d[2]] * math.pi,
        lookPitch: TrainingActions.pitchBins[d[3]] * math.pi / 2,
        jump: d[4] == 1,
        interact: d[5] == 1,
      );
      intent.validate();
      return DecodedAction._(action, character: intent);
    }
    if (pedals) {
      final intent = VehicleIntent(
        steer: v[0],
        throttle: v[2] > 0 ? 0 : v[1],
        brake: v[2],
      );
      intent.validate();
      return DecodedAction._(
        PolicyAction([intent.steer, intent.throttle, intent.brake], []),
        vehicle: intent,
      );
    }
    if (driver) {
      final intent = VehicleIntent(
        steer: v[0],
        throttle: math.max(0, v[1]),
        brake: math.max(0, -v[1]),
      );
      intent.validate();
      return DecodedAction._(action, vehicle: intent);
    }
    final intent = CharacterIntent(
      moveX: v[0],
      moveZ: v[1],
      lookYaw: look ? v[2] * math.pi : 0,
      lookPitch: look ? v[3] * math.pi / 2 : 0,
      jump: jump && action.discrete[0] == 1,
    );
    intent.validate();
    return DecodedAction._(action, character: intent);
  }
}
