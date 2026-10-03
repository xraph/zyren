import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren_game_ai/zyren_game_ai.dart';

void main() {
  test(
    'normalized character controls map look radians and reject nonfinite bounds',
    () {
      final decoder = ActionDecoder.character(look: true);
      final action = decoder.decode(PolicyAction([.5, -.5, 1, .5], []));
      expect(action!.character!.moveX, .5);
      expect(action.character!.lookYaw, math.pi);
      expect(action.character!.lookPitch, math.pi / 4);
      for (final x in [double.nan, double.infinity, 1.001]) {
        expect(decoder.decode(PolicyAction([x, 0, 0, 0], [])), isNull);
      }
      expect(decoder.fallback.character!.moveX, 0);
    },
  );
  test('vehicle signed drive maps throttle or brake, fallback brakes', () {
    final decoder = ActionDecoder.vehicle();
    expect(decoder.decode(PolicyAction([.5, .7], []))!.vehicle!.throttle, .7);
    expect(decoder.decode(PolicyAction([-.5, -.4], []))!.vehicle!.brake, .4);
    expect(decoder.fallback.vehicle!.brake, 1);
  });
  test('illegal discrete choices reject the whole action', () {
    final decoder = ActionDecoder.character(jump: true);
    expect(
      decoder.decode(
        PolicyAction([0, 0], [1]),
        legality: [
          [true, false],
        ],
      ),
      isNull,
    );
    expect(decoder.decode(PolicyAction([0, 0], [2])), isNull);
    expect(
      decoder
          .decode(
            PolicyAction([0, 0], [1]),
            legality: [
              [true, true],
            ],
          )!
          .character!
          .jump,
      isTrue,
    );
  });
}
