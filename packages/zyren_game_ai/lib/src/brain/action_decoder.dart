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
  final bool driver, look, jump;
  ActionDecoder._(
    this.spec, {
    this.driver = false,
    this.look = false,
    this.jump = false,
  });
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
  DecodedAction get fallback =>
      decode(PolicyAction(spec.fallbackContinuous, spec.fallbackDiscrete))!;
  DecodedAction? decode(PolicyAction action, {List<List<bool>>? legality}) {
    if (!spec.accepts(action.continuous, action.discrete, legality: legality)) {
      return null;
    }
    final v = action.continuous;
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
