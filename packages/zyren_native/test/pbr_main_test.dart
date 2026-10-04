import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'support/brdf_reference.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'PBR direct radiance follows pinned GGX reference and physical light falloff',
    () async {
      final reference =
          jsonDecode(
                File(
                  '../../test_assets/rendering/pbr/direct.json',
                ).readAsStringSync(),
              )
              as Map;
      final backend = await NativeBackend.create();
      final scene = Scene()
        ..background = const Color3(0, 0, 0)
        ..renderSettings = RenderSettings(toneMapping: ToneMapping.reinhard);
      final material = StandardMaterial(baseColor: const Color3(.5, .2, .1));
      final mesh = scene.add(
        Mesh(PlaneGeometry(width: 2, height: 2), material),
      );
      final light = scene.add(DirectionalLight());
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
        final i = (16 * 33 + 16) * 4;
        return output.image.pixels.sublist(i, i + 4);
      }

      int expected(double radiance) {
        final value = radiance / (1 + radiance);
        return (255 *
                (value <= .0031308
                    ? 12.92 * value
                    : 1.055 * math.pow(value, 1 / 2.4) - .055))
            .round();
      }

      try {
        for (final sample in reference['samples'] as List) {
          mesh.material = material.copyWith(
            metallic: (sample['metallic'] as num).toDouble(),
            roughness: (sample['roughness'] as num).toDouble(),
          );
          final actual = await pixel();
          final radiance = referenceRadiance(
            view: const Vec3(0, 0, 1),
            light: const Vec3(0, 0, 1),
            base: material.baseColor,
            metallic: (sample['metallic'] as num).toDouble(),
            roughness: (sample['roughness'] as num).toDouble(),
          );
          for (var i = 0; i < 3; i++) {
            expect(
              actual[i],
              closeTo(expected(radiance[i]), 2),
              reason: '$sample channel $i',
            );
          }
        }
        mesh.material = material.copyWith(metallic: 0, roughness: .5);
        final directional = await pixel();
        mesh.scale = const Vec3(-1, 1, 1);
        expect(await pixel(), directional);
        mesh.scale = Vec3.one;
        scene.remove(light);
        expect(await pixel(), [0, 0, 0, 255]);
        final point = scene.add(
          PointLight(intensity: 4)..position = const Vec3(0, 0, 2),
        );
        expect(await pixel(), directional);
        point.range = 1;
        expect(await pixel(), [0, 0, 0, 255]);
        scene.remove(point);
        final spot = scene.add(
          SpotLight(intensity: 4)..position = const Vec3(0, 0, 2),
        );
        expect(await pixel(), directional);
        spot.direction = const Vec3(1, 0, 0);
        expect(await pixel(), [0, 0, 0, 255]);
        scene.remove(spot);
        final hemisphere = scene.add(HemisphereLight(up: const Vec3(0, 0, 1)));
        final diffuse = await pixel();
        expect(diffuse[0], closeTo(expected(.5 * .96 / math.pi), 1));
        scene.remove(hemisphere);
        scene.add(light);
        final image = TextureImage.rgba(
          width: 1,
          height: 1,
          pixels: Uint8List.fromList([255, 255, 255, 0]),
        );
        mesh.material = StandardMaterial(
          colorMap: TextureMap(image: image),
          alphaMode: MaterialAlphaMode.mask,
        );
        expect(await pixel(), [0, 0, 0, 255]);
        mesh.material = StandardMaterial(
          baseColor: const Color3(.5, .2, .1),
          metallic: 0,
          roughness: .5,
          colorMap: TextureMap(image: image),
        );
        expect(await pixel(), directional);
        scene.remove(light);
        scene.renderSettings = RenderSettings(hdr: true, backgroundAlpha: 0);
        mesh.material = StandardMaterial(
          emissive: const Color3(1, 0, 0),
          alphaMode: MaterialAlphaMode.blend,
          opacity: .5,
        );
        final blended = await pixel();
        expect(blended[0], closeTo(128, 1));
        expect(blended.sublist(1), [0, 0, 128]);
        scene.renderSettings = RenderSettings(
          toneMapping: ToneMapping.reinhard,
        );
        mesh.material = StandardMaterial(
          baseColor: const Color3(0, 0, 0),
          metallic: 1,
        );
        expect(await pixel(), [0, 0, 0, 255]);
        mesh.material = material.copyWith(
          emissive: const Color3(1, 0, 0),
          emissiveIntensity: 4,
        );
        expect((await pixel())[0], closeTo(expected(4), 1));
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
