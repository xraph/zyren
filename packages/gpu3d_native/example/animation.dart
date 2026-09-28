import 'dart:io';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'support/png.dart';
// ignore: avoid_relative_lib_imports
import '../../../examples/shader_lab/lib/animation_scene.dart';

Future<void> main(List<String> args) async {
  final demo = AnimationLabScene(autoplay: false);
  demo.actions.first.seek(const Duration(milliseconds: 800));
  final backend = await NativeBackend.create();
  try {
    final frame =
        await backend.render(
              FrameSubmission.capture(
                scene: demo.scene,
                camera: demo.camera,
                size: PhysicalSize(768, 512),
                colorPipeline: ColorPipeline(),
              ),
            )
            as ReadbackOutput;
    final path = args.isEmpty ? 'animation.png' : args.first;
    await File(path).writeAsBytes(png(frame.image));
    stdout.writeln(
      '$path: ${frame.stats.drawCalls} native draws, independent 0.8 s and 2.0 s poses',
    );
  } finally {
    await backend.close();
  }
}
