import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_audio/zyren_audio.dart';

Float32List tone([int length = 4800]) => Float32List.fromList(
  List.generate(length, (i) => .2 * math.sin(i * 2 * math.pi * 440 / 48000)),
);
double energy(Float32List samples) =>
    samples.fold(0.0, (a, b) => a + b * b) / samples.length;

void main() {
  test(
    'real native mixer follows scene distance and parent/listener transforms',
    () {
      final scene = Scene(),
          listener = Group(),
          parent = Group(),
          node = Group();
      scene.add(listener);
      scene.add(parent);
      parent.add(node);
      node.position = const Vec3(0, 0, 1);
      final audio = SpatialAudio(
        root: scene,
        listener: AudioListener(listener),
        offline: true,
      );
      addTearDown(audio.close);
      final emitter = audio.add(
        id: 'tone',
        node: node,
        samples: tone(),
        settings: EmitterSettings(loop: true),
      );
      emitter.play();
      audio.renderOffline(4096);
      final near = energy(audio.renderOffline(4096));
      parent.position = const Vec3(0, 0, 9);
      audio.renderOffline(4096);
      final far = energy(audio.renderOffline(4096));
      listener.position = const Vec3(0, 0, 9);
      audio.renderOffline(4096);
      final followed = energy(audio.renderOffline(4096));
      expect(near, greaterThan(.001));
      expect(far / near, closeTo(.01, .002));
      expect(followed / near, closeTo(1, .02));
      print('miniaudio energy near=$near far=$far followed=$followed');
    },
  );

  test('listener orientation changes stereo balance in the native mixer', () {
    final root = Scene(),
        listener = Group(),
        node = Group()..position = const Vec3(1, 0, 1);
    root.add(listener);
    root.add(node);
    final audio = SpatialAudio(
      root: root,
      listener: AudioListener(listener),
      offline: true,
    );
    addTearDown(audio.close);
    audio
        .add(
          id: 'side',
          node: node,
          samples: tone(),
          settings: EmitterSettings(loop: true),
        )
        .play();
    double balance() {
      audio.renderOffline(4096);
      final samples = audio.renderOffline(4096);
      double left = 0, right = 0;
      for (var i = 0; i < samples.length; i += 2) {
        left += samples[i] * samples[i];
        right += samples[i + 1] * samples[i + 1];
      }
      return left - right;
    }

    final before = balance();
    listener.rotateY(math.pi);
    final after = balance();
    expect(before.abs(), greaterThan(1));
    expect(before * after, lessThan(0));
  });

  test('pause, removal and disposal release playback and PCM', () {
    final root = Scene(),
        listener = root.add(Group()),
        node = root.add(Group());
    final audio = SpatialAudio(
      root: root,
      listener: AudioListener(listener),
      offline: true,
    );
    addTearDown(audio.close);
    final samples = tone();
    final emitter = audio.add(
      id: 'tone',
      node: node,
      samples: samples,
      settings: EmitterSettings(loop: true),
    );
    samples.fillRange(0, samples.length, 0);
    emitter.play();
    expect(energy(audio.renderOffline(4096)), greaterThan(0));
    emitter.pause();
    expect(emitter.isPlaying, isFalse);
    expect(energy(audio.renderOffline(4096)), 0);
    emitter.play(restart: true);
    root.remove(node);
    audio.sync();
    expect(emitter.isClosed, isTrue);
    expect(audio.residentPcmBytes, 0);
    expect(audio.emitters, isEmpty);
    expect(() => emitter.play(), throwsStateError);
    audio.close();
    audio.close();
    expect(() => audio.renderOffline(1), throwsStateError);
  });

  test('removed listener stops its emitters and reports stale attachment', () {
    final root = Scene(),
        listener = root.add(Group()),
        node = root.add(Group());
    final audio = SpatialAudio(
      root: root,
      listener: AudioListener(listener),
      offline: true,
    );
    addTearDown(audio.close);
    final emitter = audio.add(id: 'tone', node: node, samples: tone())..play();
    root.remove(listener);
    expect(audio.sync, throwsStateError);
    expect(emitter.isPlaying, isFalse);
  });

  test(
    'invalid PCM, settings and bounded allocations fail before native writes',
    () {
      final root = Scene(),
          listener = root.add(Group()),
          node = root.add(Group());
      final audio = SpatialAudio(
        root: root,
        listener: AudioListener(listener),
        offline: true,
        maxPcmBytes: 16,
      );
      addTearDown(audio.close);
      for (final samples in [
        Float32List(0),
        Float32List.fromList([double.nan]),
        Float32List.fromList([2]),
        tone(),
      ]) {
        expect(
          () => audio.add(id: 'bad', node: node, samples: samples),
          throwsArgumentError,
        );
      }
      expect(
        () => EmitterSettings(minDistance: 2, maxDistance: 1),
        throwsArgumentError,
      );
      expect(
        () => AudioListener(node, localUp: const Vec3(0, 0, 1)),
        throwsArgumentError,
      );
      audio.add(id: 'small', node: node, samples: Float32List(4));
      expect(audio.residentPcmBytes, 16);
      expect(
        () => audio.add(id: 'another', node: node, samples: Float32List(1)),
        throwsArgumentError,
      );
      audio.close();
      expect(audio.residentPcmBytes, 0);
    },
  );
}
