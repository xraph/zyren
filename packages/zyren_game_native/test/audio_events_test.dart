import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/zyren_game_native.dart';
import 'package:zyren_game_native/audio.dart';
import 'support/native_game_fixture.dart';

void main() {
  test(
    'hearing survives muted speakers and disposed playback; receipts emit once',
    () async {
      final game = GameSession(project: testProject(), seed: 1)..step();
      final root = Scene();
      final listener = Group();
      final parent = Group()..position = const Vec3(10, 0, 0);
      final node = Group();
      root.add(listener);
      root.add(parent);
      parent.add(node);
      final audio = SpatialAudio(
        root: root,
        listener: AudioListener(listener),
        offline: true,
      );
      final emitter = audio.add(
        id: 'step',
        node: node,
        samples: Float32List.fromList(
          List.generate(
            4800,
            (i) => .2 * math.sin(i * 2 * math.pi * 440 / 48000),
          ),
        ),
      );
      final owner = AttachmentScope();
      final errors = <Object>[];
      final bridge = GameAudioEvents(
        events: game.events,
        audio: audio,
        scope: owner,
        onError: errors.add,
      );
      bridge.bind('step', emitter);
      final heard = <GameSoundEvent>[];
      game.events.listen((event) {
        if (event.payload is GameSoundEvent) {
          heard.add(event.payload as GameSoundEvent);
        }
      });
      final publisher = GameSoundPublisher(game);
      GameSoundEvent sound(String id) => GameSoundEvent(
        id: id,
        category: 'step',
        tick: game.tick,
        position: const Vec3(10, 0, 0),
        loudness: .5,
        range: 20,
      );
      try {
        bridge.muted = true;
        expect(publisher.emit(sound('muted')), isTrue);
        expect(publisher.emit(sound('muted')), isFalse);
        expect(heard, hasLength(1));
        expect(emitter.isPlaying, isFalse);
        bridge.muted = false;
        expect(publisher.emit(sound('audible')), isTrue);
        expect(emitter.isPlaying, isTrue);
        expect(node.position, Vec3.zero);
        expect(emitter.settings.volume, .5);
        expect(audio.renderOffline(1024).any((s) => s.abs() > .0001), isTrue);
        emitter.close();
        expect(publisher.emit(sound('closed-emitter')), isTrue);
        expect(errors, hasLength(1));
        expect(heard, hasLength(3));
        owner.close();
        await owner.whenClosed;
        expect(publisher.emit(sound('after-dispose')), isTrue);
        expect(errors, hasLength(1));
        expect(heard, hasLength(4));
        game.pause();
        expect(publisher.emit(sound('paused')), isFalse);
      } finally {
        owner.close();
        await owner.whenClosed;
        audio.close();
        await game.close();
      }
    },
  );
}
