import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

Future<void> verifyPbr(NativeGpuBackend backend) async {
  final scene = Scene()..background = const Color3(0, 0, 0);
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 2));
  var material = StandardMaterial(baseColor: const Color3(.5, .5, .5));
  final mesh = scene.add(Mesh(PlaneGeometry(width: 4, height: 4), material));
  Future<ReadbackOutput> draw() async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(31, 31),
            ),
          )
          as ReadbackOutput;
  void pixel(ReadbackOutput frame, List<int> expected) {
    final actual = frame.image.pixels.sublist(1920, 1924);
    for (var i = 0; i < 4; i++) {
      expect(
        actual[i],
        closeTo(expected[i], 2),
        reason: '$actual vs $expected',
      );
    }
  }

  pixel(await draw(), [0, 0, 0, 255]);
  final sun = scene.add(DirectionalLight());
  pixel(await draw(), [110, 110, 110, 255]);
  mesh.material = material.copyWith(metallic: 1);
  final metal = await draw();
  pixel(metal, [56, 56, 56, 255]);
  expect(metal.stats.uploadedBytes, 0);
  mesh.material = material;
  sun.visible = false;
  final point = scene.add(
    PointLight(intensity: 4)..position = const Vec3(0, 0, 2),
  );
  pixel(await draw(), [110, 110, 110, 255]);
  point.position = const Vec3(0, 0, 4);
  pixel(await draw(), [56, 56, 56, 255]);
  point.visible = false;
  final spot = scene.add(
    SpotLight(intensity: 4)..position = const Vec3(0, 0, 2),
  );
  pixel(await draw(), [110, 110, 110, 255]);
  spot.setCone(innerConeAngle: 0, outerConeAngle: .0001);
  pixel(await draw(), [110, 110, 110, 255]);
  spot.lookAt(const Vec3(2, 0, 2));
  pixel(await draw(), [0, 0, 0, 255]);
  sun.visible = true;
  final image = TextureImage.rgba(
    width: 1,
    height: 1,
    pixels: Uint8List.fromList([255, 0, 0, 128]),
  );
  material = StandardMaterial(
    baseColorMap: TextureMap(image: image),
    alphaMode: MaterialAlphaMode.mask,
    alphaCutoff: .6,
  );
  mesh.material = material;
  pixel(await draw(), [0, 0, 0, 255]);
  mesh.material = material.copyWith(alphaCutoff: .4);
  pixel(await draw(), [150, 10, 10, 255]);
  mesh.scale = const Vec3(-1, 2, 1);
  pixel(await draw(), [150, 10, 10, 255]);
  mesh.material = StandardMaterial(
    emissive: const Color3(.25, 0, 0),
    alphaMode: MaterialAlphaMode.blend,
    opacity: .5,
  );
  sun.visible = false;
  scene.background = null;
  pixel(await draw(), [137, 0, 0, 128]);
  scene.remove(mesh);
  await draw();
  expect((await backend.resourceStats()).residentBytes, 0);
}
