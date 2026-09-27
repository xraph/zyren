import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

Future<void> verifyMaterialAlpha() async {
  final backend = await NativeBackend.create();
  final scene = Scene()..background = const Color3(0, 0, 0);
  final camera = PerspectiveCamera();
  final plane = PlaneGeometry(width: 4, height: 4);
  final front = Mesh(plane, UnlitMaterial(color: const Color3(1, 0, 0)))
    ..position = const Vec3(0, 0, 1);
  final back = Mesh(plane, UnlitMaterial(color: const Color3(0, 0, 1)));
  scene
    ..add(front)
    ..add(back);
  Future<ReadbackOutput> render() async =>
      await backend.render(
            FrameSubmission.capture(
              scene: scene,
              camera: camera,
              size: PhysicalSize(31, 31),
            ),
          )
          as ReadbackOutput;
  void pixel(ReadbackOutput output, List<int> expected) {
    final actual = output.image.pixels.sublist(
      (15 * 31 + 15) * 4,
      (15 * 31 + 15) * 4 + 4,
    );
    for (var i = 0; i < 4; i++) {
      expect(actual[i], closeTo(expected[i], 1));
    }
  }

  try {
    pixel(await render(), [255, 0, 0, 255]);
    front.material = UnlitMaterial(
      color: const Color3(1, 0, 0),
      alphaMode: MaterialAlphaMode.blend,
      opacity: .5,
    );
    back.renderOrder = 10;
    front.renderOrder = -10;
    final blended = await render();
    pixel(blended, [188, 0, 188, 255]);
    expect(blended.stats.uploadedBytes, 0);
    back.renderOrder = 0;
    front.renderOrder = 0;
    front.material = DiffuseMaterial(
      color: const Color3(1, 0, 0),
      alphaMode: MaterialAlphaMode.blend,
      opacity: .5,
    );
    scene.lightDirection = const Vec3(0, 0, 1);
    pixel(await render(), [188, 0, 188, 255]);
    final image = TextureImage.rgba(
      width: 1,
      height: 1,
      pixels: Uint8List.fromList([255, 0, 0, 128]),
    );
    UnlitMaterial masked(double cutoff, {double opacity = 1}) => UnlitMaterial(
      colorMap: TextureMap(image: image),
      alphaMode: MaterialAlphaMode.mask,
      alphaCutoff: cutoff,
      opacity: opacity,
    );
    front.material = masked(.6);
    pixel(await render(), [0, 0, 255, 255]);
    front.material = masked(128 / 255);
    pixel(await render(), [255, 0, 0, 255]);
    front.material = masked(.3, opacity: .5);
    pixel(await render(), [0, 0, 255, 255]);
    front.material = masked(.2, opacity: .5);
    pixel(await render(), [255, 0, 0, 255]);
    front.material = UnlitMaterial(
      colorMap: TextureMap(image: image),
      alphaMode: MaterialAlphaMode.blend,
      opacity: .5,
    );
    pixel(await render(), [137, 0, 224, 255]);
    front.material = UnlitMaterial(color: const Color3(1, 0, 0), opacity: 0);
    pixel(await render(), [255, 0, 0, 255]);

    UnlitMaterial glass(
      Color3 color, {
      bool depthTest = true,
      DepthWrite depthWrite = DepthWrite.automatic,
    }) => UnlitMaterial(
      color: color,
      alphaMode: MaterialAlphaMode.blend,
      opacity: .5,
      depthTest: depthTest,
      depthWrite: depthWrite,
    );
    front.material = glass(const Color3(1, 0, 0));
    back.material = glass(const Color3(0, 1, 0));
    pixel(await render(), [188, 137, 0, 255]);
    scene
      ..remove(front)
      ..add(front);
    pixel(await render(), [188, 137, 0, 255]);
    camera.position = const Vec3(0, 0, -5);
    pixel(await render(), [137, 188, 0, 255]);
    camera.position = const Vec3(0, 0, 5);
    front.renderOrder = -1;
    pixel(await render(), [137, 188, 0, 255]);
    front.material = glass(
      const Color3(1, 0, 0),
      depthWrite: DepthWrite.enabled,
    );
    pixel(await render(), [188, 0, 0, 255]);
    back.material = glass(const Color3(0, 1, 0), depthTest: false);
    pixel(await render(), [137, 188, 0, 255]);

    // Geometry centers differ even though both object transforms are identical.
    scene
      ..remove(front)
      ..remove(back);
    BufferGeometry at(double z) => BufferGeometry(
      dynamic: true,
      positions: [-2, -2, z, 2, -2, z, 2, 2, z, -2, 2, z],
      normals: [0, 0, 1, 0, 0, 1, 0, 0, 1, 0, 0, 1],
      indices: [0, 1, 2, 0, 2, 3],
    );
    final near = Mesh(at(1), glass(const Color3(1, 0, 0)));
    final far = Mesh(at(0), glass(const Color3(0, 1, 0)));
    scene
      ..add(near)
      ..add(far);
    pixel(await render(), [188, 137, 0, 255]);
    near.geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList([-2, -2, -1, 2, -2, -1, 2, 2, -1, -2, 2, -1]),
    );
    pixel(await render(), [137, 188, 0, 255]);
    scene
      ..remove(near)
      ..remove(far);
    await render();
    expect((await backend.resourceStats()).residentBytes, 0);
  } finally {
    await backend.close();
  }
}
