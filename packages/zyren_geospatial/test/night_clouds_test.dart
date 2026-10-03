import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';
import 'cloud_shadow_test.dart' show constantCloudTextures;
import 'cloud_render_test.dart' show uniformClouds;
import 'aerial_perspective_test.dart' show center;

void main() {
  test(
    'cloud moonlight follows phase, horizon and night fill without altering daylight',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final date = DateTime.utc(2026, 1, 3, 12);
      final directions = CelestialDirections.at(date);
      final camera = PerspectiveCamera(near: 1, far: 1e7);
      void aim(Vec3 radial) {
        camera.position = radial * 6360100;
        camera.target = radial * 6363000;
        camera.up = radial.cross(const Vec3(0, 0, 1)).normalized();
      }

      aim(directions.moonECEF);
      final air = AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy().copyWith(
          rayleighScattering: Vec3.zero,
          mieScattering: Vec3.zero,
          mieExtinction: Vec3.zero,
          absorptionExtinction: Vec3.zero,
        ),
        correctAltitude: false,
        maxStarResolution: 16,
        appearance: AtmosphereAppearance(sky: false, haze: false),
      );
      final clouds = CloudPlugin(
        textures: await constantCloudTextures(owner),
        parameters: uniformClouds(1),
        appearance: CloudAppearance(hazeDensityScale: 0),
        quality: CloudQualityPreset.low,
        temporal: CloudTemporalSettings(mode: CloudTemporalMode.off),
        animationEnabled: false,
        maxResolution: 32,
        shadowsEnabled: false,
      );
      final engine = await SceneEngine.create(
        scene: Scene()
          ..renderSettings = RenderSettings(hdr: true, exposure: 10),
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [air, clouds],
      );
      Future<List<int>> render() async => center(
        await engine.render(elapsed: Duration.zero, width: 17, height: 17),
      );
      try {
        final unlit = air.appearance;
        final lunar = unlit.copyWith(moonLight: true, moonLightIntensity: 5000);
        final black = await render();
        expect(black.take(3), [0, 0, 0]);
        air.controller.appearance = lunar;
        final full = await render();
        expect(full[0], greaterThan(10));
        expect(full[3], black[3]);
        air.controller.appearance = lunar.copyWith(moonIntensity: 0);
        expect(await render(), full);
        air.controller.date = DateTime.utc(2026, 1, 8, 12);
        final gibbous = CelestialDirections.at(air.controller.date);
        aim(gibbous.moonECEF);
        final dimmer = await render();
        expect(dimmer[0], inExclusiveRange(0, full[0]));
        air.controller.date = DateTime.utc(2026, 1, 11, 12);
        final quarter = CelestialDirections.at(air.controller.date);
        aim(-(quarter.sunECEF + quarter.moonECEF).normalized());
        expect((await render()).take(3), [0, 0, 0]);
        air.controller.appearance = lunar.copyWith(nightLightIntensity: .02);
        expect((await render())[0], greaterThan(10));
        aim(quarter.sunECEF);
        final dayWith = await render();
        air.controller.appearance = unlit;
        expect(await render(), dayWith);
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
