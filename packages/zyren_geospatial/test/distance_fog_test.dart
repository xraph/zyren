import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';
import 'aerial_perspective_test.dart' show center, encoded;

void main() {
  test(
    'fog validates ranges and conservatively retains intersecting bounds',
    () {
      for (final range in [
        (-1.0, 20.0),
        (20.0, 20.0),
        (20.0, 10.0),
        (double.nan, 20.0),
        (0.0, double.infinity),
        (0.0, 1e9),
        (1e7, 1e7 + .001),
      ]) {
        expect(
          () => GeoDistanceFog(startMetres: range.$1, endMetres: range.$2),
          throwsArgumentError,
        );
      }
      expect(
        () => GeoDistanceFog(
          startMetres: 0,
          endMetres: 100,
          color: const Color3(-1, 0, 0),
        ),
        throwsArgumentError,
      );
      final fog = GeoDistanceFog(startMetres: 100, endMetres: 300);
      expect([0.0, 100.0, 200.0, 300.0, double.infinity].map(fog.opacityAt), [
        0,
        0,
        .5,
        1,
        1,
      ]);
      expect(() => fog.opacityAt(double.nan), throwsArgumentError);
      expect(
        fog.intersectsVisibleRange(Vec3.zero, const Vec3(350, 0, 0), 50),
        isTrue,
      );
      expect(
        fog.intersectsVisibleRange(Vec3.zero, const Vec3(350.01, 0, 0), 50),
        isFalse,
      );
      expect(
        () => fog.intersectsVisibleRange(Vec3.zero, Vec3.zero, -1),
        throwsArgumentError,
      );
    },
  );

  for (final strategy in DepthStrategy.values) {
    test(
      'native $strategy fog matches distances, empty sky, clouds and disabling',
      () async {
        final backend = await NativeBackend.create();
        final scope = GpuScope.fromBackend(backend);
        final camera = PerspectiveCamera(
          position: const Vec3(6378237, 0, 0),
          target: const Vec3(6378237, 1000, 0),
          up: const Vec3(1, 0, 0),
          near: 1,
          far: 10000,
          depthStrategy: strategy,
        );
        const materialColor = Color3(.2, .3, .4);
        final mesh = Mesh(
          PlaneGeometry(width: 2000, height: 2000),
          UnlitMaterial(color: materialColor),
        );
        final scene = Scene()
          ..renderSettings = RenderSettings(hdr: true)
          ..add(mesh);
        final atmosphere = AtmospherePlugin(
          date: DateTime.utc(2026, 3, 20, 12),
          appearance: AtmosphereAppearance(sky: false, haze: false),
        );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: camera,
          backendFactory: () async => backend.createView(),
          plugins: [atmosphere],
        );
        final fog = GeoDistanceFog(startMetres: 100, endMetres: 300);
        Future<List<int>> render([int size = 33]) async => center(
          await engine.render(
            elapsed: Duration.zero,
            width: size,
            height: size,
          ),
        );
        void matches(List<int> pixel, List<double> expected) {
          for (var c = 0; c < 3; c++) {
            expect(pixel[c], closeTo(encoded(expected[c]), 2));
          }
          expect(pixel[3], 255);
        }

        Future<GpuResource<Texture>> image(List<double> values) async {
          final texture = await scope.resources.createTexture(
            TextureDescriptor(
              width: 1,
              height: 1,
              format: TextureFormat.rgba32Float,
            ),
          );
          await scope.resources.writeTexture(
            texture,
            Float32List.fromList(values),
          );
          return texture;
        }

        try {
          await atmosphere.controller.setAerialInputs(
            AerialPerspectiveInputs(fog: fog),
          );
          for (final distance in [50.0, 200.0, 400.0]) {
            mesh.position = camera.position + Vec3(0, distance, 0);
            mesh.lookAt(camera.position);
            final amount = fog.opacityAt(distance);
            matches(await render(), [
              for (var c = 0; c < 3; c++)
                materialColor.toList()[c] * (1 - amount) +
                    fog.color.toList()[c] * amount,
            ]);
          }
          scene.remove(mesh);
          matches(await render(41), fog.color.toList());
          // Clouds use their own distance and premultiplied radiance over fog.
          final clouds = await atmosphere.controller.registerCloudInputs(
            AtmosphereCloudInputs(
              color: await image([.1, .15, .2, .5]),
              depthVelocityShadow: await image([200, 0, 0, 0]),
              transmittance: await image([1, 0, 0, 0]),
            ),
          );
          matches(await render(), [
            for (var c = 0; c < 3; c++)
              fog.color.toList()[c] * .75 + materialColor.toList()[c] * .25,
          ]);
          await clouds.close();
          await atmosphere.controller.setAerialInputs(
            AerialPerspectiveInputs(),
          );
          scene.add(mesh);
          matches(await render(), materialColor.toList());
        } finally {
          await engine.dispose();
          await scope.close();
          expect((await backend.resourceStats()).liveAllocations, 0);
          await backend.close();
        }
      },
      skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
      timeout: const Timeout(Duration(minutes: 3)),
    );
  }
}
