import 'package:test/test.dart';
import 'package:zyren_game/zyren_game.dart';

GameInputMap bindings() => GameInputMap(
  actions: [
    GameActionDefinition('move', deadZone: .2),
    GameActionDefinition('jump', button: true),
  ],
  bindings: [
    GameInputBinding('key.a', 'move', scale: -1),
    GameInputBinding('key.d', 'move'),
    GameInputBinding('axis.leftStickX', 'move'),
    GameInputBinding('key.space', 'jump'),
  ],
);
void main() {
  test(
    'brief taps latch until the next tick and disabled input cannot stick',
    () {
      final state = GameActionState(bindings());
      state.setButton(deviceId: 'touch', action: 'jump', pressed: true);
      state.setButton(deviceId: 'touch', action: 'jump', pressed: false);
      expect(state.pressed('jump'), isFalse);
      expect(state.takePressed('jump'), isTrue);
      expect(state.takePressed('jump'), isFalse);
      state.enabled = false;
      state.setButton(deviceId: 'touch', action: 'jump', pressed: true);
      state.enabled = true;
      expect(state.pressed('jump'), isFalse);
      expect(state.takePressed('jump'), isFalse);
    },
  );
  test('opposed controls retain their individual release state', () {
    final state = GameActionState(bindings());
    state.accept(
      GameInputEvent(
        deviceId: 'keyboard',
        control: 'key.d',
        value: 1,
        timestamp: 1,
      ),
    );
    state.accept(
      GameInputEvent(
        deviceId: 'keyboard',
        control: 'key.a',
        value: 1,
        timestamp: 2,
      ),
    );
    expect(state.axis('move'), 0);
    state.accept(
      GameInputEvent(
        deviceId: 'keyboard',
        control: 'key.a',
        value: 0,
        timestamp: 3,
      ),
    );
    expect(state.axis('move'), 1);
    final snapshot = state.snapshot;
    state.releaseAll('keyboard');
    expect(state.axis('move'), 0);
    expect(snapshot.values['move'], 1);
    expect(() => snapshot.values['move'] = 2, throwsUnsupportedError);
  });
  test(
    'dead zones, consumed events, stale input and disconnect are explicit',
    () {
      final state = GameActionState(bindings());
      state.accept(
        GameInputEvent(
          deviceId: 'pad',
          control: 'axis.leftStickX',
          value: .1,
          timestamp: 1,
        ),
      );
      expect(state.axis('move'), 0);
      state.accept(
        GameInputEvent(
          deviceId: 'pad',
          control: 'axis.leftStickX',
          value: .6,
          timestamp: 2,
        ),
      );
      expect(state.axis('move'), closeTo(.5, 1e-10));
      expect(
        state.accept(
          GameInputEvent(
            deviceId: 'pad',
            control: 'axis.leftStickX',
            value: 1,
            timestamp: 0,
          ),
        ),
        isFalse,
      );
      state.accept(
        GameInputEvent(
          deviceId: 'pad',
          control: 'key.space',
          value: 1,
          timestamp: 3,
        ),
      );
      expect(state.pressed('jump'), isTrue);
      state.accept(
        GameInputEvent(
          deviceId: 'pad',
          control: 'key.space',
          value: 0,
          timestamp: 4,
          consumed: true,
        ),
      );
      expect(state.pressed('jump'), isFalse);
      state.releaseAll('pad');
      expect(state.axis('move'), 0);
    },
  );
  test('rebinding clears held state and preserves immutable maps', () {
    final map = bindings();
    final state = GameActionState(map);
    state.setAxis(deviceId: 'touch', action: 'move', value: 1);
    state.setButton(deviceId: 'touch', action: 'jump', pressed: true);
    final rebound = map.rebind('key.space', GameInputBinding('key.j', 'jump'));
    state.rebind(rebound);
    expect(state.pressed('jump'), isFalse);
    expect(state.axis('move'), 0);
    expect(
      state.accept(
        GameInputEvent(
          deviceId: 'keyboard',
          control: 'key.space',
          value: 1,
          timestamp: 0,
        ),
      ),
      isFalse,
    );
    expect(
      state.accept(
        GameInputEvent(
          deviceId: 'keyboard',
          control: 'key.j',
          value: 1,
          timestamp: 1,
        ),
      ),
      isTrue,
    );
    expect(map.bindings.any((b) => b.control == 'key.space'), isTrue);
    state.releaseAll('keyboard');
    expect(state.pressed('jump'), isFalse);
  });
  test('invalid schemas, values and bounded devices fail before mutation', () {
    expect(
      () => GameInputMap(
        actions: [GameActionDefinition('x')],
        bindings: [GameInputBinding('a', 'missing')],
      ),
      throwsArgumentError,
    );
    expect(() => GameActionDefinition('x', deadZone: 1), throwsArgumentError);
    final state = GameActionState(bindings(), maxDevices: 1);
    state.setAxis(deviceId: 'one', action: 'move', value: 1);
    expect(
      () => state.setAxis(deviceId: 'two', action: 'move', value: 1),
      throwsStateError,
    );
    expect(
      () => state.setAxis(deviceId: 'one', action: 'move', value: double.nan),
      throwsArgumentError,
    );
    state.releaseAll('one');
    state.setAxis(deviceId: 'two', action: 'move', value: 1);
    expect(state.axis('move'), 1);
  });
}
