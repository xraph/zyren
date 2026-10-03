import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'character_lab_scene.dart';

/// Explicit GPU readback for the qualification artifact, separate from presentation.
Future<void> main(List<String> args) async {
  final lab = await CharacterLabScene.load();
  final engine = await SceneEngine.create(
    scene: lab.scene,
    camera: PerspectiveCamera(
      position: const Vec3(8, 6, 9),
      target: const Vec3(3, .5, 3),
    ),
    backendFactory: NativeBackend.create,
    plugins: lab.plugins,
  );
  try {
    lab.setObstacle(true);
    for (var i = 0; i < 90; i++) {
      await engine.renderFrame(
        elapsed: Duration.zero,
        time: const FrameTime(delta: CharacterLabScene.step),
        width: 640,
        height: 420,
      );
    }
    final frame =
        await engine.renderFrame(
              elapsed: Duration.zero,
              time: const FrameTime(delta: Duration.zero),
              width: 960,
              height: 630,
            )
            as ReadbackOutput;
    final pixels = frame.image.pixels, size = frame.image.size;
    final file = File(
      args.isEmpty ? '/tmp/zyren-character-lab.ppm' : args.single,
    );
    await file.writeAsBytes([
      ...'P6\n${size.width} ${size.height}\n255\n'.codeUnits,
      for (var y = 0; y < size.height; y++)
        for (var x = 0; x < size.width; x++)
          ...pixels.sublist(
            y * frame.image.rowStride + x * 4,
            y * frame.image.rowStride + x * 4 + 3,
          ),
    ]);
    stdout.writeln(
      'CHARACTER_CAPTURE backend=${engine.capabilities.backend} draws=${frame.stats.drawCalls} file=${file.path}',
    );
  } finally {
    await engine.dispose();
    await lab.close();
  }
}
