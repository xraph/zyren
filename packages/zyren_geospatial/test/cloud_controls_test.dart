import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_geospatial/src/clouds/media_uniforms.dart';
import 'package:zyren_native/zyren_native.dart';
import 'cloud_shadow_test.dart' show constantCloudTextures;
import 'cloud_render_test.dart' show uniformClouds;
import 'aerial_perspective_test.dart' show center;

void main() {
  test(
    'density reduction preserves layer proportions, coverage and motion',
    () {
      final original = CloudParameters(
        coverage: .65,
        localWeatherVelocity: (.001, -.002),
        shapeVelocity: const Vec3(.01, .02, .03),
        shapeDetailVelocity: const Vec3(.04, .05, .06),
        scatteringCoefficient: .8,
        absorptionCoefficient: .2,
      );
      expect(original.densityMultiplier, 1);
      expect(CloudPlugin(animationEnabled: false).animationEnabled, false);
      final reduced = original.copyWith(densityMultiplier: .25);
      final before = cloudMediaUniforms(
        original,
        CloudAppearance(),
        elapsed: 4,
      );
      final after = cloudMediaUniforms(reduced, CloudAppearance(), elapsed: 4);
      for (var i = 0; i < before.length; i++) {
        expect(
          after[i],
          closeTo(before[i] * (i >= 8 && i < 12 ? .25 : 1), 1e-8),
        );
      }
      expect(identical(original.layers, reduced.layers), true);
      expect(reduced.coverage, .65);
      expect(reduced.localWeatherVelocity, original.localWeatherVelocity);
      expect(reduced.shapeVelocity, original.shapeVelocity);
      expect(reduced.shapeDetailVelocity, original.shapeDetailVelocity);
      final empty = cloudMediaUniforms(
        original.copyWith(densityMultiplier: 0),
        CloudAppearance(),
      );
      expect(empty.sublist(8, 12), everyElement(0));
      for (final invalid in [-.01, 100.01, double.nan, double.infinity]) {
        expect(
          () => original.copyWith(densityMultiplier: invalid),
          throwsArgumentError,
        );
      }
    },
  );

  test(
    'paused cloud motion refines then releases demand and resumes without a jump',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final textures = await constantCloudTextures(owner);
      final date = DateTime.utc(2026, 3, 20, 12);
      final sun = CelestialDirections.at(date).sunECEF;
      final cloud = CloudPlugin(
        textures: textures,
        parameters: uniformClouds(1).copyWith(
          localWeatherVelocity: (.001, 0),
          shapeVelocity: const Vec3(.01, .02, .03),
          shapeDetailVelocity: const Vec3(.04, .05, .06),
        ),
        appearance: CloudAppearance(hazeDensityScale: 0),
        quality: CloudQualityPreset.low,
        maxResolution: 32,
        shadowMapSize: 16,
      );
      var demand = 0;
      final engine = await SceneEngine.create(
        scene: Scene()..renderSettings = RenderSettings(hdr: true),
        camera: PerspectiveCamera(
          position: sun * 6360100,
          target: sun * 6363000,
          up: const Vec3(0, 0, 1),
          near: 1,
          far: 1e7,
        ),
        backendFactory: () async => backend.createView(),
        acquireFrameDemand: () {
          demand++;
          return Registration(() => demand--);
        },
        plugins: [
          AtmospherePlugin(
            date: date,
            parameters: AtmosphereParameters.legacy(),
            correctAltitude: false,
            maxStarResolution: 32,
            appearance: AtmosphereAppearance(sky: false, haze: false),
          ),
          cloud,
        ],
      );
      var milliseconds = 0;
      Future<RenderedFrame> render() => engine.render(
        elapsed: Duration(milliseconds: milliseconds += 50),
        width: 33,
        height: 33,
      );
      try {
        await owner.close();
        await render();
        await render();
        expect(cloud.controller.animationEnabled, true);
        expect(
          cloud.controller.animationElapsed,
          const Duration(milliseconds: 50),
        );
        cloud.controller.animationEnabled = false;
        final frozen = cloud.controller.animationElapsed;
        for (var i = 0; i < 20; i++) {
          await render();
        }
        expect(cloud.controller.animationElapsed, frozen);
        expect(
          cloud.controller.history.accumulatedFrames,
          greaterThanOrEqualTo(16),
        );
        expect(demand, 0);
        final thickAlpha = center(await render())[3];
        cloud.controller.parameters = cloud.controller.parameters.copyWith(
          densityMultiplier: .1,
        );
        RenderedFrame? thin;
        for (var i = 0; i < 16; i++) {
          thin = await render();
        }
        expect(center(thin!)[3], lessThan(thickAlpha));
        cloud.controller.parameters = cloud.controller.parameters.copyWith(
          densityMultiplier: 0,
        );
        expect(demand, 1);
        for (var i = 0; i < 16; i++) {
          expect(center(await render()), [0, 0, 0, 0]);
        }
        expect(demand, 0);
        expect(cloud.controller.animationElapsed, frozen);
        await cloud.controller.setQualitySettings(
          CloudQualitySettings(
            preset: CloudQualityPreset.medium,
            maxResolution: 32,
            shadowMapSize: 16,
          ),
        );
        expect(cloud.controller.animationEnabled, false);
        expect(cloud.controller.parameters.densityMultiplier, 0);
        milliseconds += 60000;
        cloud.controller.animationEnabled = true;
        expect(demand, 1);
        await render();
        expect(cloud.controller.animationElapsed, frozen);
        await render();
        expect(
          cloud.controller.animationElapsed,
          frozen + const Duration(milliseconds: 50),
        );
        expect(cloud.controller.parameters.localWeatherVelocity, (.001, 0));
        expect(
          cloud.controller.parameters.shapeVelocity,
          const Vec3(.01, .02, .03),
        );
        expect(
          cloud.controller.parameters.shapeDetailVelocity,
          const Vec3(.04, .05, .06),
        );
        cloud.controller.animationEnabled = false;
        await cloud.controller.setTemporal(
          CloudTemporalSettings(mode: CloudTemporalMode.off),
        );
        expect(demand, 0);
      } finally {
        await engine.dispose();
        expect(demand, 0);
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
      expect(() => cloud.controller.animationEnabled = true, throwsStateError);
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
