import 'dart:io';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/png.dart';
// ignore: avoid_relative_lib_imports
import '../../../examples/shader_lab/lib/animation_scene.dart';

Future<void> main(List<String> args) async {
  final demo = AnimationLabScene(autoplay: false);
  demo.actions.first.seek(const Duration(milliseconds: 800));
  final transition = args.contains('--transition');
  if (transition) {
    demo.crossFade(0);
    demo.mixers.first.update(const Duration(milliseconds: 375));
  }
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
    final paths = args.where((arg) => arg != '--transition');
    final path = paths.isEmpty ? 'animation.png' : paths.first;
    await File(path).writeAsBytes(png(frame.image));
    stdout.writeln(
      '$path: ${frame.stats.drawCalls} native draws, '
      '${transition ? 'halfway crossfade and held right pose' : 'independent 0.8 s and 2.0 s poses'}',
    );
  } finally {
    await backend.close();
  }
}
