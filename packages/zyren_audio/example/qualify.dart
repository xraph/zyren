import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_audio/zyren_audio.dart';

/// Emits a quiet left/right tone and records transport progress, not audibility.
Future<void> main() async {
  final root = Scene(),
      listener = root.add(Group()),
      source = root.add(Group());
  final audio = SpatialAudio(root: root, listener: AudioListener(listener));
  final records = <Map<String, Object?>>[];
  try {
    final voice = audio.add(
      id: 'qualification-tone',
      node: source,
      samples: Float32List.fromList(
        List.generate(
          48000,
          (i) => .05 * math.sin(2 * math.pi * 440 * i / 48000),
        ),
      ),
      settings: EmitterSettings(loop: true),
    );
    for (final x in [-2.0, 2.0]) {
      source.position = Vec3(x, 0, 2);
      voice.play(restart: true);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      records.add({
        'x': x,
        'cursorUs': voice.cursor.inMicroseconds,
        'playing': voice.isPlaying,
      });
    }
    audio.suspend();
    final stopped = voice.cursor;
    await Future<void>.delayed(const Duration(milliseconds: 150));
    if (voice.cursor != stopped)
      throw StateError('Cursor moved during suspension.');
    audio.resume();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    records.add({
      'suspendCursorUs': stopped.inMicroseconds,
      'resumedCursorUs': voice.cursor.inMicroseconds,
    });
    print(
      jsonEncode({
        'backend': audio.backend,
        'records': records,
        'humanAudibility': 'unverified',
      }),
    );
  } finally {
    audio.close();
  }
}
