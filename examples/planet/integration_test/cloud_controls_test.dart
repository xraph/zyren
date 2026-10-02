import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/geospatial_device_profile.dart';
import 'package:planet/geospatial_presets.dart';
import 'package:planet/geospatial_scene.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native clouds freeze, refine, change density and resume', (
    tester,
  ) async {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final device = GeospatialDeviceProfile.forViewport(
      defaultTargetPlatform,
      tester.view.physicalSize.shortestSide / tester.view.devicePixelRatio,
    );
    final controller = SceneController(
      scene: Scene(),
      camera: PerspectiveCamera(near: 1, far: 1e9),
      runtime: android
          ? const SceneRuntime.nativeAndroid()
          : const SceneRuntime.nativeMetal(),
      options: const EngineOptions(
        presentation: PresentationPolicy.requireNative,
      ),
    );
    final profile = GeospatialSceneProfile(
      services: controller.runtime.assetServices,
      clouds: true,
      cloudQuality: device.clouds(),
    );
    profile.apply(controller.scene, controller.camera, GoogleTilesPreset.tokyo);
    for (final plugin in profile.plugins) {
      controller.use(plugin);
    }
    controller.use(_TileSizedPressure());
    var frames = 0;
    final subscription = controller.presentations.listen((sample) {
      final frame = sample.frame;
      expectSync(frame.readbackBytes, 0);
      expectSync(
        frame.presentationPath,
        android ? PresentationPath.sharedTexture : PresentationPath.nativeView,
      );
      frames++;
    });
    final records = <Map<String, Object?>>[];
    binding.reportData = {
      'suite': 'cloud-density-animation',
      'platform': defaultTargetPlatform.name,
      'device': device.device.name,
      'passed': false,
      'samples': records,
    };
    Future<void> tick() async {
      await tester.pump(const Duration(milliseconds: 25));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      if (controller.status.value case SceneFailed(:final issue)) {
        fail('${issue.code}: ${issue.message}; ${issue.cause}');
      }
    }

    Future<void> advance(int before, {bool refine = true}) async {
      for (var i = 0; i < 1800; i++) {
        await tick();
        if (frames > before + 2 &&
            (!refine ||
                profile.cloudLayer!.controller.history.accumulatedFrames >=
                    16)) {
          return;
        }
      }
      fail('Cloud control change did not finish rendering.');
    }

    void record(String label) {
      final clouds = profile.cloudLayer!.controller;
      records.add({
        'label': label,
        'densityMultiplier': clouds.parameters.densityMultiplier,
        'animationEnabled': clouds.animationEnabled,
        'animationElapsedUs': clouds.animationElapsed.inMicroseconds,
        'historyFrames': clouds.history.accumulatedFrames,
        'cloudQuality': clouds.quality.name,
        'presentedFrames': frames,
      });
    }

    try {
      for (final size in [const Size(1000, 700), const Size(390, 700)]) {
        final before = frames;
        await tester.binding.setSurfaceSize(size);
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: LayoutBuilder(
                builder: (context, bounds) {
                  final ratio = MediaQuery.devicePixelRatioOf(context);
                  return SceneView(
                    controller: controller,
                    resolutionScale: geospatialResolutionScale(
                      width: bounds.maxWidth * ratio,
                      height: bounds.maxHeight * ratio,
                      maxDimension: device.maxDimension,
                      maxPixels: device.maxPixels,
                    ),
                  );
                },
              ),
            ),
          ),
        );
        await advance(before);
        profile.cloudAnimationEnabled = false;
        await advance(frames);
        final clouds = profile.cloudLayer!.controller;
        final frozen = clouds.animationElapsed;
        record('paused ${size.width.toInt()}');
        final stopped = frames;
        for (var i = 0; i < 40; i++) {
          await tick();
        }
        record('idle observation');
        expect(
          frames,
          stopped,
          reason: 'Paused refined clouds should stop requesting frames.',
        );
        for (final density in [.25, 0.0, 1.0]) {
          profile.cloudDensity = density;
          await advance(frames);
          expect(clouds.parameters.densityMultiplier, density);
          expect(clouds.animationElapsed, frozen);
          record('density $density');
        }
        await profile.setCloudQuality(
          device.clouds(
            size.width == 1000
                ? CloudQualityPreset.low
                : CloudQualityPreset.medium,
          ),
        );
        await advance(frames);
        expect(clouds.animationEnabled, false);
        expect(clouds.animationElapsed, frozen);
        record('paused quality change');
        profile.cloudAnimationEnabled = true;
        await advance(frames, refine: false);
        expect(clouds.animationElapsed, greaterThan(frozen));
        record('resumed');
      }
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await controller.whenDisposed;
      await subscription.cancel();
      await tester.binding.setSurfaceSize(null);
    }
    final diagnostics = await MethodChannel(
      android ? 'zyren/android-surfaces' : 'zyren/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics');
    for (final name in [
      'sessions',
      'renderers',
      'retiring',
      'readbackBytes',
      android ? 'surfaces' : 'heldDrawables',
    ]) {
      expect(diagnostics![name], 0, reason: name);
    }
    binding.reportData!['passed'] = true;
    binding.reportData!['diagnostics'] = diagnostics;
  }, timeout: const Timeout(Duration(minutes: 5)));
}

class _TileSizedPressure extends ScenePlugin {
  @override
  String get id => 'tile-sized-resource-pressure';
  @override
  Future<void> attach(PluginContext context) async {
    await context
        .createGpuScope(label: '64 MiB tile-sized pressure')
        .resources
        .createBuffer(
          BufferDescriptor(
            size: 64 * 1024 * 1024,
            usage: {BufferUsage.storage},
          ),
        );
  }
}
