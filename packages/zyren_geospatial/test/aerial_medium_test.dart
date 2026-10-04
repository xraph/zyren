import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'native atmosphere excludes a non-air medium interval and retains its transport',
    () async {
      final backend = await NativeBackend.create();
      final view = backend.createView();
      final scope = GpuScope.fromBackend(backend);
      final origin = const Vec3(6361000, 0, 0);
      final camera = OrthographicCamera(
        position: origin,
        target: origin + const Vec3(0, 0, -10000),
        near: .1,
        far: 20000,
        verticalSize: 10,
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(
          hdr: true,
          toneMapping: ToneMapping.linear,
        );
      final floor = scene.add(
        Mesh(
          PlaneGeometry(width: 30, height: 30),
          UnlitMaterial(color: const Color3(1, 1, 1)),
        )..position = origin + const Vec3(0, 0, -10000),
      );
      final atmosphere = AtmospherePlugin(
        date: DateTime.utc(2026, 3, 20, 12),
        correctAltitude: false,
        appearance: AtmosphereAppearance(sky: false),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => view,
        plugins: [atmosphere],
      );
      final map = await scope.resources.createTexture(
        TextureDescriptor(
          width: 2,
          height: 1,
          format: TextureFormat.rgba32Float,
          usage: {TextureUsage.sampled, TextureUsage.copyDestination},
        ),
      );
      Future<List<int>> draw() async {
        final frame = await engine.render(
          elapsed: Duration.zero,
          width: 16,
          height: 16,
        );
        return frame.pixels.sublist((8 * 16 + 8) * 4, (8 * 16 + 8) * 4 + 4);
      }

      try {
        await scope.resources.writeTexture(
          map,
          Float32List.fromList([
            .2,
            .4,
            .6,
            0,
            .01,
            .02,
            .03,
            60000,
          ]).buffer.asUint8List(),
        );
        await atmosphere.controller.setAerialInputs(
          AerialPerspectiveInputs(medium: AerialMediumInputs(transport: map)),
        );
        final transported = await draw();
        for (var c = 0; c < 3; c++) {
          expect(transported[c], closeTo(srgb([.21, .42, .63][c]), 2));
        }
        expect(transported[3], 255);
        Future<void> medium(List<double> values) async {
          await scope.resources.writeTexture(
            map,
            Float32List.fromList(values).buffer.asUint8List(),
          );
          await atmosphere.controller.setAerialInputs(
            AerialPerspectiveInputs(medium: AerialMediumInputs(transport: map)),
          );
        }

        void sameColor(List<int> actual, List<int> expected) {
          for (var c = 0; c < 4; c++) {
            expect(actual[c], closeTo(expected[c], 2));
          }
        }

        // Opaque medium removes far-air radiance. Render a separate source at
        // its near boundary to check the remaining air segment independently.
        await medium([0, 0, 0, 3000, .4, .3, .2, 6000]);
        final nearAir = await draw();
        await atmosphere.controller.setAerialInputs(AerialPerspectiveInputs());
        floor.position = origin + const Vec3(0, 0, -3000);
        floor.material = UnlitMaterial(color: const Color3(.4, .3, .2));
        sameColor(nearAir, await draw());
        floor.position = origin + const Vec3(0, 0, -10000);
        floor.material = UnlitMaterial(color: const Color3(1, 1, 1));
        await medium([1, 1, 1, 0, 0, 0, 0, 6000]);
        final farAir = await draw();
        await atmosphere.controller.setAerialInputs(AerialPerspectiveInputs());
        camera.position = origin + const Vec3(0, 0, -6000);
        sameColor(farAir, await draw());
        camera.position = origin;
        await medium([.2, .4, .6, 0, .01, .02, .03, 60000]);
        await scope.close();
        expect(await draw(), transported);
        await atmosphere.controller.setAerialInputs(AerialPerspectiveInputs());
        expect(await draw(), isNot(transported));
      } finally {
        await engine.dispose();
        await scope.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}

int srgb(double value) =>
    (255 *
            (value <= .0031308
                ? value * 12.92
                : 1.055 * math.pow(value, 1 / 2.4) - .055))
        .round();
