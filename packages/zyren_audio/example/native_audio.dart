import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren_audio/zyren_audio.dart';

Future<void> main(List<String> args) async {
  final root = Scene(),
      listener = root.add(Group()),
      source = root.add(Group());
  source.position = const Vec3(2, 0, 2);
  final offline = !args.contains('--play') && !args.contains('--device-check');
  final audio = SpatialAudio(
    root: root,
    listener: AudioListener(listener),
    offline: offline,
  );
  try {
    print('Native backend: ${audio.backend}');
    if (args.contains('--device-check')) return;
    final pcm = Float32List.fromList(
      List.generate(48000, (i) => .1 * math.sin(i * 2 * math.pi * 440 / 48000)),
    );
    audio.add(id: 'tone', node: source, samples: pcm).play();
    if (offline) {
      final samples = audio.renderOffline(48000);
      print('Rendered ${samples.length ~/ 2} stereo PCM frames.');
    } else {
      await Future<void>.delayed(const Duration(seconds: 1));
    }
  } finally {
    audio.close();
  }
}
