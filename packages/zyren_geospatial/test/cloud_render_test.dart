import 'package:test/test.dart';
import 'dart:math' as math;
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';
import 'cloud_shadow_test.dart' show constantCloudTextures;
import 'aerial_perspective_test.dart' show center;

CloudParameters uniformClouds(double coverage) => CloudParameters(
  coverage: coverage,
  layers: CloudLayers([
    CloudLayer(
      altitude: 1000,
      height: 1000,
      densityScale: .01,
      shapeAmount: 0,
      shapeDetailAmount: 0,
      shadow: true,
      densityProfile: CloudDensityProfile(constantTerm: 1),
    ),
  ]),
);
void main() {
  test(
    'cloud atlas shadows ground lighting and follows date and world frame',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      final textures = await constantCloudTextures(owner),
          date = DateTime.utc(2026, 3, 20, 12);
      final sun = CelestialDirections.at(date).sunECEF;
      final camera = PerspectiveCamera(
        position: sun * 6360100,
        target: sun * 6360000,
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 1e7,
      );
      final wall = Mesh(
        PlaneGeometry(width: 4000, height: 4000),
        UnlitMaterial(color: const Color3(.4, .4, .4)),
      )..position = sun * 6360000;
      wall.lookAt(camera.position);
      final scene = Scene()
        ..renderSettings = RenderSettings(hdr: true)
        ..add(wall);
      final air = AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 32,
        appearance: AtmosphereAppearance(
          sky: false,
          haze: false,
          sunLight: true,
        ),
      );
      final clouds = CloudPlugin(
        temporal: CloudTemporalSettings(mode: CloudTemporalMode.off),
        textures: textures,
        parameters: uniformClouds(0),
        appearance: CloudAppearance(hazeDensityScale: 0),
        quality: CloudQualityPreset.low,
        maxResolution: 32,
        shadowMapSize: 32,
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [air, clouds],
      );
      Future<List<int>> render() async => center(
        await engine.render(elapsed: Duration.zero, width: 17, height: 17),
      );
      try {
        await owner.close();
        for (final depth in DepthStrategy.values) {
          camera.depthStrategy = depth;
          clouds.controller.parameters = uniformClouds(0);
          air.controller.appearance = air.controller.appearance.copyWith(
            skyLight: false,
          );
          final lit = await render();
          expect(lit[0], greaterThan(40));
          clouds.controller.parameters = uniformClouds(1);
          final shadow = await render();
          double linear(int value) => value <= 10
              ? value / 255 / 12.92
              : math.pow((value / 255 + .055) / 1.055, 2.4).toDouble();
          expect(linear(shadow[0]), lessThan(linear(lit[0]) * .5));
          expect(shadow[3], 255);
          air.controller.appearance = air.controller.appearance.copyWith(
            skyLight: true,
          );
          final ambient = await render();
          expect(ambient[0], greaterThan(shadow[0]));
          expect(ambient[0], lessThan(lit[0]));
        }
        scene.remove(wall);
        camera.target = sun * 6363000;
        final day = await render();
        expect(day[0], greaterThan(30));
        air.controller.date = date.add(const Duration(hours: 12));
        final night = await render();
        expect(night[0], lessThan(day[0] ~/ 2));
        expect(night[3], day[3]);
        final origin = camera.position;
        final localOwner = GpuScope.fromBackend(backend);
        final localMaps = await constantCloudTextures(localOwner);
        final localEngine = await SceneEngine.create(
          scene: Scene()..renderSettings = RenderSettings(hdr: true),
          camera: PerspectiveCamera(
            position: Vec3.zero,
            target: sun * 2900,
            up: camera.up,
            near: 1,
            far: 1e7,
            depthStrategy: camera.depthStrategy,
          ),
          backendFactory: () async => backend.createView(),
          plugins: [
            AtmospherePlugin(
              date: date,
              worldToEcef: Mat4([
                1,
                0,
                0,
                0,
                0,
                1,
                0,
                0,
                0,
                0,
                1,
                0,
                origin.x,
                origin.y,
                origin.z,
                1,
              ]),
              parameters: AtmosphereParameters.legacy(),
              correctAltitude: false,
              maxStarResolution: 32,
              appearance: AtmosphereAppearance(
                sky: false,
                haze: false,
                sunLight: true,
                skyLight: true,
              ),
            ),
            CloudPlugin(
              temporal: CloudTemporalSettings(mode: CloudTemporalMode.off),
              textures: localMaps,
              parameters: uniformClouds(1),
              appearance: CloudAppearance(hazeDensityScale: 0),
              quality: CloudQualityPreset.low,
              maxResolution: 32,
              shadowMapSize: 32,
            ),
          ],
        );
        try {
          final local = center(
            await localEngine.render(
              elapsed: Duration.zero,
              width: 17,
              height: 17,
            ),
          );
          for (var i = 0; i < 4; i++) {
            expect(local[i], closeTo(day[i], 2));
          }
        } finally {
          await localEngine.dispose();
          await localOwner.close();
        }
        final bytes = (await backend.resourceStats()).residentBytes;
        for (var i = 0; i < 4; i++) {
          await render();
        }
        expect((await backend.resourceStats()).residentBytes, bytes);
      } finally {
        await owner.close();
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
  test(
    'procedural default textures produce a visible native cloud field',
    () async {
      final backend = await NativeBackend.create(),
          date = DateTime.utc(2026, 3, 20, 12);
      final sun = CelestialDirections.at(date).sunECEF;
      final air = AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 32,
        appearance: AtmosphereAppearance(sky: false, haze: false),
      );
      final clouds = CloudPlugin(
        temporal: CloudTemporalSettings(mode: CloudTemporalMode.off),
        quality: CloudQualityPreset.low,
        maxResolution: 32,
        shadowMapSize: 16,
      );
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
        plugins: [air, clouds],
      );
      try {
        final frame = await engine.render(
          elapsed: Duration.zero,
          width: 31,
          height: 31,
        );
        final alpha = [
          for (var i = 3; i < frame.pixels.length; i += 4) frame.pixels[i],
        ];
        expect(alpha.where((v) => v > 10).length, greaterThan(50));
        expect(alpha.toSet().length, greaterThan(5));
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
  test(
    'native cloud layer clips against the scene from below, inside and above',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      final textures = await constantCloudTextures(owner),
          date = DateTime.utc(2026, 3, 20, 12);
      final sun = CelestialDirections.at(date).sunECEF;
      final camera = PerspectiveCamera(
        position: sun * 6360100,
        target: sun * 6363000,
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 1e7,
      );
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      final air = AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 32,
        appearance: AtmosphereAppearance(sky: false, haze: false),
      );
      final clouds = CloudPlugin(
        temporal: CloudTemporalSettings(mode: CloudTemporalMode.off),
        textures: textures,
        parameters: uniformClouds(1),
        appearance: CloudAppearance(hazeDensityScale: 0),
        quality: CloudQualityPreset.low,
        maxResolution: 32,
        shadowMapSize: 16,
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [air, clouds],
      );
      Future<RenderedFrame> render([int size = 17]) =>
          engine.render(elapsed: Duration.zero, width: size, height: size);
      try {
        await owner.close();
        for (final depth in DepthStrategy.values) {
          for (final orthographic in [false, true]) {
            engine.camera = orthographic
                ? OrthographicCamera(
                    position: camera.position,
                    target: camera.target,
                    up: camera.up,
                    left: -300,
                    right: 300,
                    bottom: -300,
                    top: 300,
                    near: 1,
                    far: 1e7,
                    depthStrategy: depth,
                  )
                : PerspectiveCamera(
                    position: camera.position,
                    target: camera.target,
                    up: camera.up,
                    near: 1,
                    far: 1e7,
                    depthStrategy: depth,
                  );
            clouds.controller.parameters = uniformClouds(1);
            final cloudy = center(await render());
            expect(cloudy[3], greaterThan(100));
            expect(cloudy.take(3).any((v) => v > 20), isTrue);
            clouds.controller.parameters = uniformClouds(0);
            expect(center(await render()), [0, 0, 0, 0]);
            clouds.controller.parameters = uniformClouds(1);
            final wall = Mesh(
              PlaneGeometry(width: 4000, height: 4000),
              UnlitMaterial(color: const Color3(.1, 0, 0)),
            )..position = sun * 6360500;
            wall.lookAt(engine.camera.position);
            scene.add(wall);
            final occluded = center(await render());
            expect(occluded[1], 0);
            expect(occluded[2], 0);
            expect(occluded[3], 255);
            wall.position = sun * 6363500;
            final behind = center(await render());
            expect(behind[1], greaterThan(10));
            scene.remove(wall);
            engine.camera.position = sun * 6361500;
            engine.camera.target = sun * 6364000;
            expect(center(await render())[3], greaterThan(100));
            engine.camera.position = sun * 6364000;
            engine.camera.target = sun * 6360000;
            expect(center(await render())[3], greaterThan(100));
          }
        }
        for (final size in [31, 47, 17]) {
          expect(center(await render(size))[3], greaterThan(100));
        }
        final resident = (await backend.resourceStats()).residentBytes;
        await expectLater(
          clouds.controller.setTextures(textures),
          throwsStateError,
        );
        expect((await backend.resourceStats()).residentBytes, resident);
        expect(center(await render())[3], greaterThan(100));
        await clouds.controller.setQuality(CloudQualityPreset.medium);
        expect(center(await render())[3], greaterThan(100));
      } finally {
        await owner.close();
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
}
