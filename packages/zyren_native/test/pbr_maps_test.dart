import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'PBR data, normal, occlusion and emissive maps affect the intended terms',
    () async {
      final backend = await NativeBackend.create();
      TextureMap map(List<int> rgba, {bool srgb = false}) => TextureMap(
        image: TextureImage.rgba(
          width: 1,
          height: 1,
          pixels: Uint8List.fromList(rgba),
          format: srgb
              ? TextureFormat.rgba8UnormSrgb
              : TextureFormat.rgba8Unorm,
        ),
      );
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
      final mesh = scene.add(
        Mesh(PlaneGeometry(width: 2, height: 2), StandardMaterial()),
      );
      final camera = OrthographicCamera(
        left: -1,
        right: 1,
        top: 1,
        bottom: -1,
        near: 0,
        far: 10,
        position: const Vec3(0, 0, 3),
      );
      Future<List<int>> pixel() async {
        final output =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(33, 33),
                  ),
                )
                as ReadbackOutput;
        final p = (16 * 33 + 16) * 4;
        return output.image.pixels.sublist(p, p + 4);
      }

      try {
        final hemisphere = scene.add(
          HemisphereLight(up: const Vec3(0, 0, 1), intensity: math.pi),
        );
        final white = await pixel();
        mesh.material = StandardMaterial(occlusionMap: map([0, 0, 0, 255]));
        expect(await pixel(), [0, 0, 0, 255]);
        mesh.material = StandardMaterial(
          occlusionMap: map([0, 0, 0, 255]),
          occlusionStrength: 0,
        );
        expect(await pixel(), white);
        scene.remove(hemisphere);
        final sun = scene.add(DirectionalLight());
        mesh.material = StandardMaterial(
          metallic: 1,
          roughness: 128 / 255,
          baseColor: const Color3(.4, .2, .1),
        );
        final scalar = await pixel();
        mesh.material = StandardMaterial(
          metallic: 1,
          roughness: 1,
          baseColor: const Color3(.4, .2, .1),
          metallicRoughnessMap: map([0, 128, 255, 255]),
          occlusionMap: map([0, 0, 0, 255]),
        );
        expect(await pixel(), scalar);
        mesh.material = StandardMaterial(normalMap: map([255, 128, 128, 255]));
        final dark = await pixel();
        sun.direction = const Vec3(-1, 0, 0);
        final lit = await pixel();
        expect(lit[0], greaterThan(dark[0] + 30));
        mesh.material = (mesh.material as StandardMaterial).copyWith(
          normalScaleX: -1,
        );
        expect((await pixel())[0], lessThan(5));
        mesh.material = (mesh.material as StandardMaterial).copyWith(
          normalScaleX: 1,
        );
        mesh.scale = const Vec3(-1, 1, 1);
        expect((await pixel())[0], lessThan(5));
        sun.direction = const Vec3(1, 0, 0);
        expect((await pixel())[0], greaterThan(dark[0] + 30));
        mesh.scale = Vec3.one;
        scene.remove(sun);
        mesh.material = StandardMaterial(emissive: const Color3(1, 0, 0));
        final emission = await pixel();
        mesh.material = StandardMaterial(
          emissive: const Color3(.5, .5, .5),
          emissiveIntensity: 2,
          emissiveMap: map([255, 0, 0, 255], srgb: true),
          occlusionMap: map([0, 0, 0, 255]),
        );
        expect(await pixel(), emission);
        scene.remove(mesh);
        await pixel();
        expect((await backend.resourceStats()).residentBytes, 0);
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
