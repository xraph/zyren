import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_audio/zyren_audio.dart';
import 'audio_test.dart' show tone;

Uint8List wav() {
  const rate = 24000, frames = 48000;
  final bytes = Uint8List(44 + frames * 2), d = ByteData.view(bytes.buffer);
  void tag(int offset, String s) => bytes.setAll(offset, s.codeUnits);
  tag(0, 'RIFF');
  d.setUint32(4, bytes.length - 8, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  d.setUint32(16, 16, Endian.little);
  d.setUint16(20, 1, Endian.little);
  d.setUint16(22, 1, Endian.little);
  d.setUint32(24, rate, Endian.little);
  d.setUint32(28, rate * 2, Endian.little);
  d.setUint16(32, 2, Endian.little);
  d.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  d.setUint32(40, frames * 2, Endian.little);
  for (var i = 0; i < frames; i++) {
    d.setInt16(
      44 + i * 2,
      (6000 * math.sin(2 * math.pi * 440 * i / rate)).round(),
      Endian.little,
    );
  }
  return bytes;
}

double energy(Float32List samples) =>
    samples.fold<double>(0, (a, b) => a + b * b) / samples.length;
void main() {
  test(
    'suspension preserves cursors and paused intent, gain affects native energy',
    () {
      final root = Scene(),
          listener = root.add(Group()),
          node = root.add(Group()..position = const Vec3(0, 0, 1));
      final audio = SpatialAudio(
        root: root,
        listener: AudioListener(listener),
        offline: true,
      );
      addTearDown(audio.close);
      final voice = audio.add(
        id: 'one',
        node: node,
        samples: tone(),
        settings: EmitterSettings(loop: true),
      );
      voice.play();
      audio.renderOffline(480);
      final cursor = voice.cursor;
      audio.suspend();
      audio.suspend();
      expect(audio.isSuspended, true);
      expect(voice.isPlaying, true);
      expect(() => audio.renderOffline(480), throwsStateError);
      expect(voice.cursor, cursor);
      voice.pause();
      audio.resume();
      expect(voice.isPlaying, false);
      voice.synchronize(
        const Duration(milliseconds: 50),
        playing: true,
        tolerance: Duration.zero,
      );
      expect(voice.cursor.inMilliseconds, 50);
      final full = energy(audio.renderOffline(4800));
      voice.setOcclusionGain(.25);
      audio.renderOffline(4800); // Flush native gain smoothing.
      final blocked = energy(audio.renderOffline(4800));
      expect(blocked / full, closeTo(.0625, .005));
      voice.setVelocity(const Vec3(0, 0, -10));
      audio.setListenerVelocity(Vec3.zero);
      expect(
        () => voice.setVelocity(const Vec3(0, 0, 301)),
        throwsArgumentError,
      );
      expect(
        () => voice.seek(const Duration(seconds: 10)),
        throwsArgumentError,
      );
      voice.synchronize(
        const Duration(milliseconds: 150),
        playing: false,
        tolerance: Duration.zero,
      );
      expect(voice.cursor.inMilliseconds, 50);
      expect(voice.isPlaying, false);
      audio.close();
      audio.close();
      expect(audio.residentPcmBytes, 0);
    },
  );
  test(
    'real file stream decodes at source rate, rejects missing files, releases voice',
    () async {
      final dir = await Directory.systemTemp.createTemp('zyren-audio-stream-');
      addTearDown(() => dir.delete(recursive: true));
      final file = await File('${dir.path}/tone.wav').writeAsBytes(wav());
      final root = Scene(),
          listener = root.add(Group()),
          node = root.add(Group()..position = const Vec3(0, 0, 1));
      final audio = SpatialAudio(
        root: root,
        listener: AudioListener(listener),
        offline: true,
        maxEmitters: 1,
      );
      addTearDown(audio.close);
      expect(
        () => audio.addFile(
          id: 'missing',
          node: node,
          path: '${dir.path}/missing.wav',
        ),
        throwsA(isA<AudioException>()),
      );
      expect(audio.emitters, isEmpty);
      final voice = audio.addFile(id: 'stream', node: node, path: file.path);
      expect(voice.streaming, true);
      expect(voice.duration, const Duration(seconds: 2));
      expect(audio.residentPcmBytes, 0);
      voice.play();
      expect(energy(audio.renderOffline(4800)), greaterThan(.001));
      voice.pause();
      voice.seek(const Duration(milliseconds: 750));
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(voice.cursor.inMilliseconds, closeTo(750, 1));
      voice.play();
      // The mixer commits streamed seeks, then the decoder fills fresh pages.
      var resumedEnergy = 0.0;
      for (var attempt = 0; attempt < 20 && resumedEnergy <= .001; attempt++) {
        resumedEnergy = energy(audio.renderOffline(480));
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(resumedEnergy, greaterThan(.001));
      expect(
        () => audio.addFile(id: 'extra', node: node, path: file.path),
        throwsArgumentError,
      );
      voice.close();
      expect(audio.emitters, isEmpty);
      audio.addFile(id: 'again', node: node, path: file.path).close();
    },
  );
}
