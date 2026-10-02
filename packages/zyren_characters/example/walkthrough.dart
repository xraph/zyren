import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'walkthrough_scene.dart';

/// Run with the workspace Flutter SDK's Dart. Writes the final native frame.
Future<void> main(List<String> args) async {
  final demo = await WalkthroughScene.load();
  SceneEngine? engine;
  try {
    final camera = PerspectiveCamera()..position = const Vec3(4, 3, 5);
    camera.lookAt(const Vec3(1, .6, 1));
    engine = await SceneEngine.create(
      scene: demo.scene,
      camera: camera,
      backendFactory: NativeBackend.create,
      plugins: [demo.timeline, demo.character],
    );
    await engine.renderFrame(
      elapsed: Duration.zero,
      time: const FrameTime(delta: Duration.zero),
      width: 480,
      height: 360,
    );
    for (var i = 0; i < 250; i++) {
      demo.advance();
      await engine.renderFrame(
        elapsed: Duration.zero,
        time: const FrameTime(delta: WalkthroughScene.step),
        width: 480,
        height: 360,
      );
    }
    final frame =
        await engine.renderFrame(
              elapsed: Duration.zero,
              time: const FrameTime(delta: Duration.zero),
              width: 480,
              height: 360,
            )
            as ReadbackOutput;
    final image = frame.image;
    final output = File(
      args.isEmpty ? '/tmp/zyren-character-walkthrough.ppm' : args.single,
    );
    await output.writeAsBytes([
      ...'P6\n${image.size.width} ${image.size.height}\n255\n'.codeUnits,
      for (var i = 0; i < image.pixels.length; i += 4)
        ...image.pixels.sublist(i, i + 3),
    ]);
    stdout.writeln(
      'backend=${engine.capabilities.backend} arrived=${demo.arrived} state=${demo.character.currentState} frame=${output.path}',
    );
  } finally {
    await engine?.dispose();
    await demo.close();
  }
}
