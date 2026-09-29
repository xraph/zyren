import 'dart:io';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';

void main() {
  test('dispersion matches three independent refractive paths', () async {
    final backend = await NativeBackend.create();
    try {
      final scene = Scene()..background = const Color3(0, 0, 0);
      final pixels = Uint8List.fromList([
        for (var i = 0; i < 256; i++) ...[i, i, i, 255],
      ]);
      scene.add(
        Mesh(
          PlaneGeometry(width: 4, height: 4),
          UnlitMaterial(
            colorMap: TextureMap(
              image: TextureImage.rgba(width: 256, height: 1, pixels: pixels),
            ),
          ),
        )..position = const Vec3(0, 0, -1),
      );
      final glass = scene.add(
        Mesh(PlaneGeometry(width: 4, height: 4), PhysicalMaterial())
          ..rotateY(.7),
      );
      Future<List<int>> draw(double ior, double dispersion) async {
        glass.material = PhysicalMaterial(
          transmission: 1,
          thickness: 1.5,
          roughness: 0,
          specularIntensity: 0,
          ior: ior,
          dispersion: dispersion,
        );
        final image =
            (await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: PerspectiveCamera(
                          position: const Vec3(0, 0, 3),
                        ),
                        size: PhysicalSize(127, 127),
                      ),
                    )
                    as ReadbackOutput)
                .image;
        return image.pixels.sublist(
          (63 * 127 + 63) * 4,
          (63 * 127 + 63) * 4 + 4,
        );
      }

      final dispersed = await draw(2, 8);
      final red = await draw(1.8, 0),
          green = await draw(2, 0),
          blue = await draw(2.2, 0);
      expect(red[0] - blue[2], greaterThan(3));
      expect(dispersed[0], closeTo(red[0], 1));
      expect(dispersed[1], closeTo(green[1], 1));
      expect(dispersed[2], closeTo(blue[2], 1));
      expect(dispersed[3], 255);
    } finally {
      await backend.close();
    }
  }, skip: Platform.environment['RUN_NATIVE_GPU'] != '1');

  test(
    'thin film changes hue with thickness and retains zero-factor output',
    () async {
      final backend = await NativeBackend.create();
      try {
        final scene = Scene()
          ..background = const Color3(0, 0, 0)
          ..add(DirectionalLight(intensity: 3)..lookAt(const Vec3(0, 0, -1)));
        final mesh = scene.add(
          Mesh(PlaneGeometry(width: 4, height: 4), PhysicalMaterial()),
        );
        Future<List<int>> draw(PhysicalMaterial m) async {
          mesh.material = m;
          final output =
              await backend.render(
                    FrameSubmission.capture(
                      scene: scene,
                      camera: PerspectiveCamera(position: const Vec3(0, 0, 3)),
                      size: PhysicalSize(31, 31),
                    ),
                  )
                  as ReadbackOutput;
          return output.image.pixels.sublist(1920, 1923);
        }

        final base = PhysicalMaterial(
          baseColor: const Color3(0, 0, 0),
          roughness: .7,
        );
        final reference = await draw(base);
        expect(
          await draw(
            base.copyWith(iridescenceIor: 2, iridescenceThicknessMaximum: 500),
          ),
          reference,
        );
        final a = await draw(
          base.copyWith(iridescence: 1, iridescenceThicknessMaximum: 250),
        );
        final b = await draw(
          base.copyWith(iridescence: 1, iridescenceThicknessMaximum: 400),
        );
        // Khronos Fourier thin-film reference at normal incidence, scaled by
        // GGX D*V and intensity 3, then encoded to sRGB (roughness 0.7).
        for (var channel = 0; channel < 3; channel++) {
          expect(a[channel], closeTo([62, 45, 15][channel], 2));
          expect(b[channel], closeTo([21, 55, 34][channel], 2));
        }
        expect(
          await draw(
            base.copyWith(iridescence: 1, iridescenceThicknessMaximum: 0),
          ),
          reference,
        );
        expect(a, isNot(reference));
        expect(a, isNot(b));
        expect(a.toSet().length, greaterThan(1));
      } finally {
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
