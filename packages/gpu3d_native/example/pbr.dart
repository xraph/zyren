import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'support/png.dart';

Future<void> main(List<String> args) async {
  final backend = await NativeBackend.create();
  final scene = Scene()..background = const Color3(.012, .018, .028);
  final geometry = SphereGeometry(
    radius: .5,
    widthSegments: 48,
    heightSegments: 32,
  );
  for (var row = 0; row < 3; row++) {
    for (var column = 0; column < 4; column++) {
      scene.add(
        Mesh(
          geometry,
          StandardMaterial(
            baseColor: const Color3(.85, .5, .12),
            metallic: row * .5,
            roughness: const [.1, .35, .65, 1.0][column],
          ),
        )..position = Vec3((column - 1.5) * 1.35, (1 - row) * 1.35, 0),
      );
    }
  }
  scene.add(
    DirectionalLight(intensity: 3)
      ..rotateY(.5)
      ..rotateX(-.4),
  );
  scene.add(
    PointLight(color: const Color3(.3, .5, 1), intensity: 4)
      ..position = const Vec3(-3, 1, 3),
  );
  try {
    final output =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(
                  position: const Vec3(0, 0, 6),
                  fieldOfView: 1.05,
                ),
                size: PhysicalSize(768, 512),
              ),
            )
            as ReadbackOutput;
    final path = args.isEmpty ? 'native-pbr.png' : args.single;
    await File(path).writeAsBytes(png(output.image));
    stdout.writeln('$path: ${output.stats.drawCalls} native PBR draws');
  } finally {
    await backend.close();
  }
}
