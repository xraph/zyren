import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'support/png.dart';
// ignore: avoid_relative_lib_imports
import '../../../examples/model_viewer/lib/deformation_scene.dart';

Future<void> main(List<String> args) async {
  final scene = Scene()..background = const Color3(.025, .04, .065);
  final geometry = deformationRibbon();
  final blue = addDeformationRig(
    scene,
    geometry,
    x: -.85,
    color: const Color3(.2, .8, .95),
  );
  final orange = addDeformationRig(
    scene,
    geometry,
    x: .85,
    color: const Color3(1, .45, .18),
  );
  blue.tip.rotateZ(.7);
  blue.mesh.setMorphWeight(0, .8);
  orange.tip.rotateZ(-.45);
  orange.mesh.setMorphWeight(0, -.25);
  scene.add(
    DirectionalLight(
      intensity: 2.5,
      shadow: DirectionalShadow(cascades: 2, distance: 12, normalBias: 0),
    )..lookAt(const Vec3(.4, -.5, -1)),
  );
  scene.add(HemisphereLight(intensity: .4));
  scene.add(
    Mesh(
        PlaneGeometry(width: 6, height: 4),
        StandardMaterial(baseColor: const Color3(.07, .1, .15), roughness: 1),
      )
      ..position = const Vec3(0, 0, -.35)
      ..receiveShadow = true,
  );
  final backend = await NativeBackend.create();
  try {
    final frame =
        await backend.render(
              FrameSubmission.capture(
                scene: scene,
                camera: PerspectiveCamera(position: const Vec3(0, 0, 4.6)),
                size: PhysicalSize(768, 512),
              ),
            )
            as ReadbackOutput;
    final path = args.isEmpty ? 'deformation.png' : args.first;
    await File(path).writeAsBytes(png(frame.image));
    stdout.writeln(
      '$path: ${frame.stats.drawCalls} draws, shared source geometry and independent two-joint poses',
    );
  } finally {
    await backend.close();
  }
}
