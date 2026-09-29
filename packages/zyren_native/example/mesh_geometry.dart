import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/png.dart';
// ignore: avoid_relative_lib_imports
import '../../../examples/shader_lab/lib/geometry_scene.dart';

Future<void> main(List<String> args) async {
  final demo = GeometryLabScene(autoplay: false);
  if (args.contains('--colors')) demo.setColors(true);
  demo.action.seek(const Duration(seconds: 1));
  final engine = await SceneEngine.create(
    scene: demo.scene,
    camera: demo.camera,
    backendFactory: NativeBackend.create,
    plugins: [demo.mixer, ...demo.patterns],
  );
  try {
    final frame =
        await engine.renderFrame(
              elapsed: Duration.zero,
              width: 768,
              height: 512,
            )
            as ReadbackOutput;
    final paths = args.where((arg) => arg != '--colors');
    final path = paths.isEmpty ? 'mesh-geometry.png' : paths.first;
    await File(path).writeAsBytes(png(frame.image));
    stdout.writeln(
      '$path: ${frame.stats.drawCalls} native draws, one skin and twelve instances with mixed winding',
    );
  } finally {
    await engine.dispose();
  }
}
