import 'dart:io';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:test/test.dart';

void main() {
  test(
    'zero-thickness film preserves area lighting with and without shadows',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final mesh = scene.add(
          Mesh(PlaneGeometry(width: 4, height: 4), PhysicalMaterial())
            ..receiveShadow = true,
        );
        final light = scene.add(
          RectAreaLight(width: 3, height: 2, intensity: 4)
            ..position = const Vec3(.3, .2, 2),
        );
        Future<Uint8List> draw(PhysicalMaterial material) async {
          mesh.material = material;
          return (await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: PerspectiveCamera(position: const Vec3(0, 0, 3)),
                      size: PhysicalSize(31, 31),
                    ),
                  )
                  as ReadbackOutput)
              .image
              .pixels;
        }

        for (final shadow in [null, AreaShadow()]) {
          light.shadow = shadow;
          for (final roughness in [.08, .5]) {
            final material = PhysicalMaterial(
              baseColor: const Color3(.25, .15, .1),
              metallic: .8,
              roughness: roughness,
            );
            expect(
              await draw(
                material.copyWith(
                  iridescence: 1,
                  iridescenceThicknessMaximum: 0,
                ),
              ),
              await draw(material),
            );
          }
        }
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );

  test(
    'area-shadow geometric bias does not follow a receiver normal map',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()..background = const Color3(0, 0, 0);
        final mapped = PhysicalMaterial(
          specularIntensity: 0,
          normalMap: TextureMap(
            image: TextureImage.rgba(
              width: 1,
              height: 1,
              format: TextureFormat.rgba8Unorm,
              pixels: Uint8List.fromList([218, 128, 218, 255]),
            ),
          ),
        );
        scene.add(
          Mesh(PlaneGeometry(width: 10, height: 10), mapped)
            ..receiveShadow = true,
        );
        scene.add(
          Mesh(PlaneGeometry(width: 1.1, height: 1.5), UnlitMaterial())
            ..position = const Vec3(0, 0, 1.5)
            ..castShadow = true,
        );
        final light = scene.add(
          RectAreaLight(
            width: 2,
            height: 2,
            intensity: 3,
            shadow: AreaShadow(
              resolution: 256,
              normalBias: 1.3,
              filterRadius: 0,
              slopeBias: 0,
            ),
          )..position = const Vec3(0, 0, 3),
        );
        Future<int> draw() async =>
            (await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: PerspectiveCamera(
                          position: const Vec3(4, 0, 3),
                        ),
                        size: PhysicalSize(63, 63),
                      ),
                    )
                    as ReadbackOutput)
                .image
                .pixels[(31 * 63 + 31) * 4];
        final shadowed = await draw();
        light.shadow = null;
        expect(await draw(), greaterThan(50));
        expect(
          shadowed,
          lessThan(5),
          reason: 'The geometric offset stays behind the full blocker.',
        );
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
