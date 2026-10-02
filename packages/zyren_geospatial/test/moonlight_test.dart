import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test(
    'moonlight settings preserve disk brightness and reject invalid gains',
    () {
      final original = AtmosphereAppearance(
        moonLight: true,
        moonLightIntensity: 5000,
        nightLightIntensity: .02,
        moonIntensity: 3,
      );
      final changed = original.copyWith(haze: false);
      expect(changed.moonLight, true);
      expect(changed.moonLightIntensity, 5000);
      expect(changed.nightLightIntensity, .02);
      expect(changed.moonIntensity, 3);
      expect(AtmosphereAppearance().moonLight, false);
      expect(AtmosphereAppearance().nightLightIntensity, 0);
      for (final value in [-1.0, double.nan, double.infinity, 100001.0]) {
        expect(
          () => AtmosphereAppearance(moonLightIntensity: value),
          throwsArgumentError,
        );
      }
      expect(
        () => AtmosphereAppearance(nightLightIntensity: 1.01),
        throwsArgumentError,
      );
    },
  );

  test(
    'native moonlight relights night tiles, respects masks and preserves day',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final date = DateTime.utc(2026, 1, 3, 12);
      final full = CelestialDirections.at(date);
      expect(full.sunECEF.dot(full.moonECEF), lessThan(-.95));
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      final camera = PerspectiveCamera(near: 1, far: 1e7);
      final mesh = Mesh(
        PlaneGeometry(width: 2000, height: 2000),
        UnlitMaterial(color: const Color3(.4, .3, .2)),
      );
      scene.add(mesh);
      final plugin = AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy().copyWith(
          rayleighScattering: Vec3.zero,
          mieScattering: Vec3.zero,
          mieExtinction: Vec3.zero,
          absorptionExtinction: Vec3.zero,
        ),
        correctAltitude: false,
        maxStarResolution: 16,
        appearance: AtmosphereAppearance(
          sky: false,
          haze: false,
          sunLight: true,
          reconstructNormal: true,
        ),
      );
      void view(Vec3 radial) {
        camera.position = radial * 6361000;
        camera.target = radial * 6360000;
        camera.up = radial.cross(const Vec3(0, 0, 1)).normalized();
        mesh.position = camera.target;
        mesh.lookAt(camera.position);
      }

      view(full.moonECEF);
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      Future<List<int>> render() async {
        final frame = await engine.render(
          elapsed: Duration.zero,
          width: 17,
          height: 17,
        );
        final center = (8 * 17 + 8) * 4;
        return frame.pixels.sublist(center, center + 3);
      }

      final noMoon = plugin.appearance;
      final moon = noMoon.copyWith(moonLight: true, moonLightIntensity: 5000);
      try {
        final black = await render();
        expect(black, [0, 0, 0]);
        plugin.controller.appearance = moon;
        final lit = await render();
        expect(lit[0], greaterThan(5));
        expect(lit[0], greaterThan(lit[2]));
        plugin.controller.appearance = moon.copyWith(moonIntensity: 0);
        expect(
          await render(),
          lit,
          reason: 'Hiding the disk retains surface light.',
        );
        plugin.controller.appearance = moon.copyWith(moonLightIntensity: 0);
        expect(await render(), black);

        final gibbousDate = DateTime.utc(2026, 1, 8, 12);
        final gibbous = CelestialDirections.at(gibbousDate);
        expect(
          gibbous.sunECEF.dot(gibbous.moonECEF),
          inExclusiveRange(-.95, -.1),
        );
        plugin.controller.date = gibbousDate;
        plugin.controller.appearance = moon;
        view(gibbous.moonECEF);
        final dimmer = await render();
        expect(dimmer[0], inExclusiveRange(0, lit[0]));
        plugin.controller.date = date;
        view(full.moonECEF);

        final mask = await owner.resources.createTexture(
          TextureDescriptor(
            width: 1,
            height: 1,
            format: TextureFormat.rgba32Float,
          ),
        );
        await owner.resources.writeTexture(
          mask,
          Float32List.fromList([0, 0, 0, 0]).buffer.asUint8List(),
        );
        plugin.controller.appearance = moon;
        await plugin.controller.setAerialInputs(
          AerialPerspectiveInputs(lightingMask: mask),
        );
        final bypass = await render();
        expect(bypass[0], greaterThan(lit[0]));
        await plugin.controller.setAerialInputs(AerialPerspectiveInputs());

        // Night fill provides visibility when a quarter Moon is below the horizon.
        final quarterDate = DateTime.utc(2026, 1, 11, 12);
        final quarter = CelestialDirections.at(quarterDate);
        final hidden = -(quarter.sunECEF + quarter.moonECEF).normalized();
        expect(hidden.dot(quarter.sunECEF), lessThan(-.1));
        expect(hidden.dot(quarter.moonECEF), lessThan(-.1));
        plugin.controller.date = quarterDate;
        view(hidden);
        expect(await render(), black);
        plugin.controller.appearance = moon.copyWith(nightLightIntensity: .02);
        expect((await render())[0], greaterThan(10));

        view(quarter.sunECEF);
        final dayWithFill = await render();
        plugin.controller.appearance = noMoon;
        expect(
          await render(),
          dayWithFill,
          reason: 'Night controls retain daylight.',
        );
      } finally {
        await engine.dispose();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
