import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';
import 'cloud_shadow_test.dart' show constantCloudTextures;
import 'cloud_render_test.dart' show uniformClouds;
import 'aerial_perspective_test.dart' show center;

void main() {
  test(
    'default temporal clouds can replace full targets within the native budget',
    () async {
      final backend = await NativeBackend.create(),
          date = DateTime.utc(2026, 3, 20, 12);
      final sun = CelestialDirections.at(date).sunECEF;
      final cloud = CloudPlugin();
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
        plugins: [
          AtmospherePlugin(
            date: date,
            parameters: AtmosphereParameters.legacy(),
            correctAltitude: false,
            maxStarResolution: 32,
          ),
          cloud,
        ],
      );
      try {
        for (final (w, h) in [(512, 512), (513, 511), (512, 512)]) {
          final image = await engine.render(
            elapsed: Duration.zero,
            width: w,
            height: h,
          );
          expect(image.pixels.any((v) => v != 0), true);
          expect(
            (await backend.resourceStats()).residentBytes,
            lessThan(64 * 1024 * 1024),
          );
        }
      } finally {
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
    timeout: Timeout(Duration(minutes: 3)),
  );
  test(
    'temporal clouds retain ordinary motion and reject cuts, edits and failed frames',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend),
          date = DateTime.utc(2026, 3, 20, 12);
      final sun = CelestialDirections.at(date).sunECEF;
      final textures = await constantCloudTextures(owner);
      final clouds = CloudPlugin(
        textures: textures,
        parameters: uniformClouds(1),
        temporal: CloudTemporalSettings(),
        quality: CloudQualityPreset.low,
        maxResolution: 64,
        shadowMapSize: 16,
        appearance: CloudAppearance(hazeDensityScale: 0),
      );
      final camera = PerspectiveCamera(
        position: sun * 6360100,
        target: sun * 6363000,
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 1e7,
      );
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      final failing = _FailFrame();
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [
          AtmospherePlugin(
            date: date,
            parameters: AtmosphereParameters.legacy(),
            correctAltitude: false,
            maxStarResolution: 32,
            appearance: AtmosphereAppearance(sky: false, haze: false),
          ),
          clouds,
          failing,
        ],
      );
      Future<RenderedFrame> render([int size = 33]) =>
          engine.render(elapsed: Duration.zero, width: size, height: size);
      try {
        expect(clouds.controller.history.valid, false);
        expect(center(await render())[3], greaterThan(100));
        expect(clouds.controller.history.accumulatedFrames, 1);
        final bytes = (await backend.resourceStats()).residentBytes;
        for (var i = 0; i < 17; i++) {
          camera.position += const Vec3(0, 0, .1);
          camera.target += const Vec3(0, 0, .1);
          final frame = await render();
          expect(center(frame)[3], greaterThan(100));
          expect(frame.uploadedBytes, 0);
        }
        expect(clouds.controller.history.accumulatedFrames, 18);
        expect((await backend.resourceStats()).residentBytes, bytes);
        final wall = Mesh(
          PlaneGeometry(width: 4000, height: 4000),
          UnlitMaterial(color: const Color3(.2, 0, 0)),
        )..position = sun * 6360500;
        wall.lookAt(camera.position);
        scene.add(wall);
        final blocked = center(await render());
        expect(blocked[1], 0);
        expect(blocked[2], 0);
        expect(blocked[3], 255);
        scene.remove(wall);
        expect(center(await render())[1], greaterThan(10));
        failing.onFrame = () => clouds.controller.parameters = uniformClouds(0);
        await render();
        expect(clouds.controller.history.valid, false);
        failing.onFrame = null;
        clouds.controller.parameters = uniformClouds(0);
        expect(center(await render()), [0, 0, 0, 0]);
        expect(clouds.controller.history.accumulatedFrames, 1);
        clouds.controller.parameters = uniformClouds(1);
        await render();
        await render();
        scene.renderSettings = scene.renderSettings.copyWith(historyEpoch: 1);
        await render();
        expect(clouds.controller.history.reason, CloudHistoryReset.sceneCut);
        expect(clouds.controller.history.accumulatedFrames, 1);
        await render(47);
        expect(clouds.controller.history.accumulatedFrames, 1);
        camera.depthStrategy = DepthStrategy.reversed;
        await render(47);
        expect(clouds.controller.history.reason, CloudHistoryReset.projection);
        failing.fail = true;
        await expectLater(render(47), throwsStateError);
        failing.fail = false;
        await render(47);
        expect(clouds.controller.history.reason, CloudHistoryReset.failedFrame);
        clouds.controller.resetHistory();
        await render(47);
        expect(clouds.controller.history.reason, CloudHistoryReset.explicit);
        await clouds.controller.setQualitySettings(
          CloudQualitySettings(
            preset: CloudQualityPreset.medium,
            maxResolution: 24,
            shadowMapSize: 8,
          ),
        );
        expect(clouds.controller.quality, CloudQualityPreset.medium);
        expect(clouds.controller.maxResolution, 24);
        expect(clouds.controller.shadowMapSize, 8);
        expect(clouds.controller.width, 24);
        expect(clouds.controller.height, 24);
        expect(clouds.controller.history.valid, false);
        expect(center(await render(47))[3], greaterThan(100));
        expect(clouds.controller.history.accumulatedFrames, 1);
        final resizedBytes = (await backend.resourceStats()).residentBytes;
        await clouds.controller.setQualitySettings(clouds.controller.settings);
        await render(47);
        expect(clouds.controller.history.accumulatedFrames, 2);
        expect((await backend.resourceStats()).residentBytes, resizedBytes);
        final pressure = owner.createChild(
          label: 'quality replacement pressure',
        );
        try {
          for (var i = 0; i < 2; i++) {
            await pressure.resources.createBuffer(
              BufferDescriptor(
                size: 64 * 1024 * 1024,
                usage: {BufferUsage.storage},
              ),
            );
          }
          final beforeFailure = (await backend.resourceStats()).residentBytes;
          await expectLater(
            clouds.controller.setQualitySettings(
              CloudQualitySettings(
                preset: CloudQualityPreset.ultra,
                maxResolution: 1024,
                shadowMapSize: 1024,
              ),
            ),
            throwsA(isA<Exception>()),
          );
          expect(clouds.controller.quality, CloudQualityPreset.medium);
          expect(clouds.controller.maxResolution, 24);
          expect(clouds.controller.shadowMapSize, 8);
          expect((await backend.resourceStats()).residentBytes, beforeFailure);
          expect(center(await render(47))[3], greaterThan(100));
        } finally {
          await pressure.close();
        }
        await clouds.controller.setQuality(CloudQualityPreset.low);
        expect(clouds.controller.maxResolution, 24);
        expect(clouds.controller.shadowMapSize, 8);
        await render(47);
        engine.camera = OrthographicCamera(
          position: camera.position,
          target: camera.target,
          up: camera.up,
          left: -300,
          right: 300,
          bottom: -300,
          top: 300,
          near: 1,
          far: 1e7,
          depthStrategy: DepthStrategy.reversed,
        );
        expect(center(await render(47))[3], greaterThan(100));
        expect(clouds.controller.history.reason, CloudHistoryReset.projection);
        expect(center(await render(47))[3], greaterThan(100));
        await clouds.controller.setTemporal(
          CloudTemporalSettings(mode: CloudTemporalMode.antialias),
        );
        await render(47);
        expect(clouds.controller.history.accumulatedFrames, 1);
        await clouds.controller.setTemporal(
          CloudTemporalSettings(mode: CloudTemporalMode.off),
        );
        expect(center(await render(47))[3], greaterThan(100));
      } finally {
        await engine.dispose();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}

class _FailFrame extends ScenePlugin {
  bool fail = false;
  void Function()? onFrame;
  @override
  String get id => 'test-cloud-failure';
  @override
  Set<String> get dependencies => {'clouds'};
  @override
  void beforeRender(PluginContext context, FrameInfo frame) {
    if (fail) throw StateError('intentional frame failure');
    onFrame?.call();
  }
}
