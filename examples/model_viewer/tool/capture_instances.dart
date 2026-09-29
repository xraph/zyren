import 'dart:io';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:model_viewer/instancing_scene.dart';
import 'capture.dart' show png;

Future<void> main(List<String> args) async {
  final backend = await NativeBackend.create();
  try {
    final scene = Scene();
    populateInstances(scene);
    final output =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(
                  position:
                      Vec3(
                        math.sin(.4) * math.cos(.65),
                        math.sin(.65),
                        math.cos(.4) * math.cos(.65),
                      ) *
                      150,
                  far: 1000,
                ),
                size: PhysicalSize(1000, 700),
              ),
            )
            as ReadbackOutput;
    final path = args.isEmpty ? 'instances.png' : args.single;
    await File(path).writeAsBytes(png(output.image));
    stdout.writeln(
      '$path: ${output.stats.drawCalls} draw, ${output.stats.triangles} triangles, ${output.stats.uploadedBytes} bytes uploaded, ${backend.capabilities.name}',
    );
  } finally {
    await backend.close();
  }
}
