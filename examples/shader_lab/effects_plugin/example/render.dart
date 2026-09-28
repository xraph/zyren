import 'dart:io';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:shader_lab_effects/shader_lab_effects.dart';
import '../../../../packages/gpu3d_native/example/support/png.dart';

Future<void> main(List<String> args) async {
  final backend = await NativeBackend.create();
  final effects = EffectsPlugin(
    options: EffectsOptions(exposure: .4, saturation: .25, vignette: .8),
  );
  final scene = Scene()..background = const Color3(.04, .06, .09);
  for (final (x, color) in [
    (-1.5, const Color3(.85, .06, .035)),
    (0.0, const Color3(.045, .7, .22)),
    (1.5, const Color3(.06, .22, .95)),
  ]) {
    scene.add(
      Mesh(BoxGeometry(), DiffuseMaterial(color: color))
        ..position = Vec3(x, 0, 0),
    );
  }
  final engine = await SceneEngine.create(
    scene: scene,
    camera: PerspectiveCamera(position: const Vec3(3, 2, 7)),
    backendFactory: () async => backend,
    plugins: [effects],
  );
  try {
    final output =
        await engine.renderFrame(
              elapsed: Duration.zero,
              width: 768,
              height: 432,
            )
            as ReadbackOutput;
    final path = args.isEmpty ? 'shader-lab.png' : args.single;
    File(path).writeAsBytesSync(png(output.image));
    print(
      'Saved $path: ${output.stats.drawCalls} draws, '
      '${effects.state.graphBuilds} graph build.',
    );
  } finally {
    await engine.dispose();
  }
}
