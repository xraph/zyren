import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

Future<void> verifyMaterialSides() async {
  final backend = await NativeBackend.create();
  expect(
    backend.capabilities.supports(RenderFeature.materialSidedness),
    isTrue,
  );
  final scene = Scene()
    ..background = const Color3(0, 0, 0)
    ..ambient = 0;
  final camera = PerspectiveCamera();
  final plane = Mesh(PlaneGeometry(width: 4, height: 4), UnlitMaterial());
  final parent = Group()..add(plane);
  scene.add(parent);
  final image = TextureImage.rgba(
    width: 1,
    height: 1,
    pixels: Uint8List.fromList([255, 255, 255, 255]),
  );
  Future<ReadbackOutput> render() async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(31, 31),
            ),
          )
          as ReadbackOutput;
  void pixel(ReadbackOutput output, bool visible, String reason) {
    final actual = output.image.pixels.sublist(
      (15 * 31 + 15) * 4,
      (15 * 31 + 15) * 4 + 4,
    );
    expect(actual, visible ? [255, 0, 0, 255] : [0, 0, 0, 255], reason: reason);
  }

  try {
    var first = true;
    for (final textured in [false, true]) {
      var textureUploaded = !textured;
      for (final (parentScale, localScale) in [
        (Vec3.one, Vec3.one),
        (const Vec3(-1, 1, 1), Vec3.one),
        (const Vec3(1, -2, 1), Vec3.one),
        (const Vec3(1, 1, -2), Vec3.one),
        (const Vec3(-1, 2, 1), const Vec3(-2, 1, 1)),
      ]) {
        parent.scale = parentScale;
        plane.scale = localScale;
        for (final cameraSign in [1.0, -1.0]) {
          camera.position = Vec3(0, 0, cameraSign * 5);
          scene.lightDirection = Vec3(0, 0, cameraSign);
          final front = parentScale.z * localScale.z * cameraSign > 0;
          for (final side in MaterialSide.values) {
            final visible =
                side == MaterialSide.doubleSided ||
                (side == MaterialSide.front && front) ||
                (side == MaterialSide.back && !front);
            for (final lit in [false, true]) {
              final map = textured ? TextureMap(image: image) : null;
              plane.material = lit
                  ? DiffuseMaterial(
                      color: const Color3(1, 0, 0),
                      colorMap: map,
                      side: side,
                    )
                  : UnlitMaterial(
                      color: const Color3(1, 0, 0),
                      colorMap: map,
                      side: side,
                    );
              final output = await render();
              pixel(
                output,
                visible,
                'side=$side parent=$parentScale local=$localScale camera=$cameraSign lit=$lit textured=$textured',
              );
              if (!first && textureUploaded) {
                expect(output.stats.uploadedBytes, 0);
              }
              first = false;
              textureUploaded = true;
            }
          }
        }
      }
    }
    scene.remove(parent);
    await render();
    expect((await backend.resourceStats()).residentBytes, 0);
  } finally {
    await backend.close();
  }
}
