import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'support/png.dart';
// Shared Dart-only fixture for the two PBR examples.
// ignore: avoid_relative_lib_imports
import '../../../examples/shader_lab/lib/studio_environment.dart';

Future<void> main(List<String> args) async {
  final backend = await NativeBackend.create();
  final resources = backend.createResourceScope();
  final scene = Scene()..background = const Color3(.012, .018, .028);
  TextureMap image(List<int> pixels, {bool srgb = false}) => TextureMap(
    image: TextureImage.rgba(
      width: 2,
      height: 2,
      pixels: Uint8List.fromList(pixels),
      format: srgb ? TextureFormat.rgba8UnormSrgb : TextureFormat.rgba8Unorm,
    ),
    sampler: const SamplerDescriptor(
      wrapU: TextureWrap.repeat,
      wrapV: TextureWrap.repeat,
    ),
  );
  final normal = image([
    192,
    128,
    238,
    255,
    64,
    128,
    238,
    255,
    128,
    192,
    238,
    255,
    128,
    64,
    238,
    255,
  ]);
  final packed = image([
    255,
    255,
    255,
    255,
    60,
    128,
    255,
    255,
    60,
    128,
    255,
    255,
    255,
    255,
    255,
    255,
  ]);
  final emission = image([
    255,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
    0,
    0,
    0,
    255,
    0,
    128,
    255,
    255,
  ], srgb: true);
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
              normalMap: normal,
              metallicRoughnessMap: packed,
              occlusionMap: packed,
              emissiveMap: emission,
              emissive: const Color3(.03, .03, .03),
              metallic: row * .5,
              roughness: const [.1, .35, .65, 1.0][column],
            ),
          )
          ..position = Vec3((column - 1.5) * 1.35, (1 - row) * 1.35, 0)
          ..castShadow = true
          ..receiveShadow = true,
      );
    }
  }
  scene.add(
    Mesh(
        PlaneGeometry(width: 9, height: 7),
        StandardMaterial(baseColor: const Color3(.08, .1, .14), roughness: .9),
      )
      ..position = const Vec3(0, 0, -1)
      ..receiveShadow = true,
  );
  scene.add(
    HemisphereLight(
      skyColor: const Color3(.5, .65, 1),
      groundColor: const Color3(.15, .1, .06),
    ),
  );
  scene.add(
    DirectionalLight(intensity: 3, shadow: DirectionalShadow(distance: 20))
      ..rotateY(.5)
      ..rotateX(-.4),
  );
  scene.add(
    PointLight(color: const Color3(.3, .5, 1), intensity: 4)
      ..position = const Vec3(-3, 1, 3),
  );
  try {
    final environment = await EnvironmentMap.fromEquirectangular(
      studioEnvironment(),
      resources: resources,
    );
    final output =
        await backend.render(
              FrameSubmission.capture(
                colorPipeline: ColorPipeline(),
                environment: Environment(map: environment),
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
    await resources.close();
    await backend.close();
  }
}
