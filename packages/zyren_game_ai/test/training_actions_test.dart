import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';
import 'package:zyren_game_native/zyren_game_native.dart';

void main() {
  test(
    'character branches and typed intent share deployed mapping and masks',
    () {
      final decoder = ActionDecoder.characterDiscrete();
      expect(decoder.spec.branches.map((b) => b.choices.length), [
        5,
        5,
        5,
        3,
        2,
        2,
      ]);
      final action = TrainingActions.encodeCharacter(
        const CharacterIntent(moveX: .5, moveZ: -1, jump: true),
      );
      expect(action.discrete, [3, 0, 2, 1, 1, 0]);
      expect(decoder.decode(action)!.character!.moveX, .5);
      final legality = [
        for (final b in decoder.spec.branches)
          List.filled(b.choices.length, false),
      ];
      for (var i = 0; i < legality.length; i++) {
        legality[i][decoder.spec.fallbackDiscrete[i]] = true;
      }
      expect(decoder.decode(action, legality: legality), isNull);
      expect(
        decoder.decode(decoder.fallback.action, legality: legality),
        isNotNull,
      );
    },
  );
  test('vehicle has separate pedals and brake priority matches execution', () {
    final decoder = ActionDecoder.vehiclePedals();
    final decoded = decoder.decode(PolicyAction([.5, .7, .8], []))!;
    expect(decoded.vehicle!.throttle, 0);
    expect(decoded.vehicle!.brake, .8);
    expect(decoded.action.continuous, [.5, 0, .8]);
    expect(decoder.decode(PolicyAction([0, -.1, 0], [])), isNull);
    expect(
      TrainingActions.encodeVehicle(
        const VehicleIntent(throttle: 1, brake: .5),
      ).continuous,
      [0, 0, .5],
    );
    expect(ActionDecoder.character().spec.continuous.length, 2);
    expect(ActionDecoder.vehicle().spec.continuous.length, 2);
  });
}
