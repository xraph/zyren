import 'dart:async';
import 'package:flutter/services.dart';
import 'input_test.dart' as fixture;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren_audio/flutter_zyren_audio.dart';
import 'package:flutter_zyren_game/flutter_zyren_game.dart';
import 'package:zyren_game/zyren_game.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('lifecycle still pauses a silent game without audio focus', () async {
    final session = fixture.session();
    final actions = fixture.actions();
    final binding = GameLifecycleBinding(
      session: session,
      actions: actions,
      observe: false,
    );
    actions.setAxis(deviceId: 'pad', action: 'move', value: 1);
    await binding.setForeground(false);
    expect(session.paused, isTrue);
    expect(actions.axis('move'), 0);
    await binding.setForeground(true);
    expect(session.paused, isFalse);
    binding.dispose();
    await session.close();
  });
  test(
    'background pauses the clock and audio, clears input and resumes fresh',
    () async {
      final session = GameSession(
        project: CompiledGameProject(
          project: GameProject(
            id: 'game',
            startupLevel: 'level',
            levels: [
              GameLevel(
                id: 'level',
                scene: GameSceneIdentity('scene', 'pin'),
                entities: [],
              ),
            ],
            registry: GameRegistry(),
          ),
        ),
        seed: 1,
      );
      final actions = GameActionState(
        GameInputMap(actions: [GameActionDefinition('move')], bindings: []),
      );
      var suspended = 0;
      var resumed = 0;
      final audio = AudioFocusSession(
        suspend: () => suspended++,
        resume: () => resumed++,
        onError: (e) => fail('$e'),
        mobile: false,
      );
      final binding = GameLifecycleBinding(
        session: session,
        actions: actions,
        audio: audio,
        observe: false,
      );
      await audio.play();
      actions.setAxis(deviceId: 'pad', action: 'move', value: 1);
      session.step();
      final epoch = session.epoch;
      await binding.setForeground(false);
      expect(session.paused, isTrue);
      expect(session.epoch, greaterThan(epoch));
      expect(actions.axis('move'), 0);
      expect(audio.allowed, isFalse);
      actions.setAxis(deviceId: 'pad', action: 'move', value: 1);
      session.step();
      expect(session.tick, 1);
      await binding.setForeground(true);
      expect(session.paused, isFalse);
      expect(actions.axis('move'), 0);
      expect(suspended, 1);
      expect(resumed, 2);
      session.pause();
      await binding.setForeground(false);
      await binding.setForeground(true);
      expect(session.paused, isTrue);
      binding.dispose();
      audio.dispose();
      await audio.released;
      await session.close();
    },
  );
  test(
    'a late foreground grant cannot resume a newer background pause',
    () async {
      const channel = MethodChannel('test/game-focus');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final grant = Completer<bool>();
      var delayed = false;
      messenger.setMockMethodCallHandler(
        channel,
        (call) async =>
            call.method == 'acquire' ? (delayed ? grant.future : true) : null,
      );
      final session = GameSession(
        project: CompiledGameProject(
          project: GameProject(
            id: 'g',
            startupLevel: 'l',
            levels: [
              GameLevel(
                id: 'l',
                scene: GameSceneIdentity('s', 'p'),
                entities: [],
              ),
            ],
            registry: GameRegistry(),
          ),
        ),
        seed: 1,
      );
      final actions = GameActionState(
        GameInputMap(actions: [GameActionDefinition('move')], bindings: []),
      );
      final audio = AudioFocusSession(
        suspend: () {},
        resume: () {},
        onError: (e) => fail('$e'),
        mobile: true,
        channel: channel,
      );
      final binding = GameLifecycleBinding(
        session: session,
        actions: actions,
        audio: audio,
        observe: false,
      );
      await audio.play();
      await binding.setForeground(false);
      delayed = true;
      final foreground = binding.setForeground(true);
      await Future<void>.delayed(Duration.zero);
      await binding.setForeground(false);
      grant.complete(true);
      await foreground;
      expect(session.paused, isTrue);
      expect(actions.enabled, isFalse);
      binding.dispose();
      audio.dispose();
      await audio.released;
      await session.close();
      messenger.setMockMethodCallHandler(channel, null);
    },
  );
}
