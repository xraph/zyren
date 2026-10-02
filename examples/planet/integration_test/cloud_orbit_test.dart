import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/geospatial_device_profile.dart';
import 'package:planet/geospatial_presets.dart';
import 'package:planet/geospatial_scene.dart';
import 'package:planet/preset_globe_controls.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('clouds survive gesture zoom from the city to space and back', (
    tester,
  ) async {
    final android = defaultTargetPlatform == TargetPlatform.android;
    final device = GeospatialDeviceProfile.forViewport(
      defaultTargetPlatform,
      tester.view.physicalSize.shortestSide / tester.view.devicePixelRatio,
    );
    final camera = PerspectiveCamera(near: 1, far: 1e9);
    final scene = Scene()
      ..add(
        Mesh(
          EllipsoidGeometry(longitudeSegments: 64, latitudeSegments: 32),
          StandardMaterial(
            baseColor: const Color3(.04, .12, .18),
            roughness: .9,
          ),
        ),
      );
    final controller = SceneController(
      scene: scene,
      camera: camera,
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
    profile.apply(scene, camera, GoogleTilesPreset.tokyo);
    controller.use(GeospatialPlugin());
    for (final plugin in profile.plugins) {
      controller.use(plugin);
    }
    controller.use(PresetGlobeControlsPlugin());
    controller.use(_TileSizedPressure());
    FrameStats? last;
    var frames = 0;
    final subscription = controller.frameStats.listen((frame) {
      expectSync(frame.readbackBytes, 0);
      expectSync(
        frame.presentationPath,
        android ? PresentationPath.sharedTexture : PresentationPath.nativeView,
      );
      last = frame;
      frames++;
    });
    final records = <Map<String, Object?>>[];
    binding.reportData = {
      'suite': 'cloud-orbital-zoom',
      'platform': defaultTargetPlatform.name,
      'passed': false,
      'samples': records,
    };
    Future<void> advance(int before, {bool refine = false}) async {
      for (var i = 0; i < 1800; i++) {
        await tester.pump(const Duration(milliseconds: 25));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        if (controller.status.value case SceneFailed(:final issue)) {
          fail('${issue.code}: ${issue.message}; ${issue.cause}');
        }
        if (frames > before &&
            (!refine ||
                profile.cloudLayer!.controller.history.accumulatedFrames >=
                    16)) {
          return;
        }
        if (i % 10 == 0) controller.invalidate();
      }
      fail(
        'Cloud orbital frame did not arrive at near=${camera.near}, far=${camera.far}.',
      );
    }

    void record(String label) {
      final data = <String, Object?>{
        'label': label,
        'distance': camera.position.length,
        'near': camera.near,
        'far': camera.far,
        'cloudQuality': profile.cloudQuality.preset.name,
        'shadowsEnabled': profile.cloudQuality.shadowsEnabled,
        'shadowQuality': profile.cloudLayer!.controller.shadowQuality.name,
        'readbackBytes': last!.readbackBytes,
      };
      records.add(data);
      debugPrint('Cloud orbit: $data');
    }

    try {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
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
      await advance(0, refine: true);
      record('city');
      final point = tester.getCenter(find.byType(SceneView));
      final pointer = TestPointer(71, PointerDeviceKind.trackpad);
      await tester.sendEventToBinding(pointer.panZoomStart(point));
      for (var step = 1; step <= 64; step++) {
        final before = frames;
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(point, pan: Offset(0, -400.0 * step)),
        );
        await advance(before);
        expect(camera.position.isFinite, true);
        expect(camera.far, greaterThan(camera.near));
        if (step % 8 == 0) record('outward $step');
      }
      await tester.sendEventToBinding(pointer.panZoomEnd());
      expect(camera.position.length, greaterThan(6378137 * 2));
      expect(camera.near, greaterThan(camera.far * .25));
      await advance(frames, refine: true);
      for (final (enabled, quality) in [
        (false, CloudQualityPreset.high),
        (true, CloudQualityPreset.low),
        (true, CloudQualityPreset.ultra),
      ]) {
        await profile.setCloudQuality(device.clouds(quality, enabled));
        await advance(frames, refine: true);
        record('space quality ${quality.name}');
      }
      await profile.setCloudQuality(device.clouds());
      await advance(frames, refine: true);
      // Real touch contacts exercise the mobile pinch path from orbit.
      final beforePinch = camera.position.length;
      final first = await tester.startGesture(
        point - const Offset(40, 0),
        pointer: 81,
      );
      final second = await tester.startGesture(
        point + const Offset(40, 0),
        pointer: 82,
      );
      for (var step = 1; step <= 6; step++) {
        final before = frames;
        await first.moveTo(point - Offset(40.0 + step * 12, 0));
        await second.moveTo(point + Offset(40.0 + step * 12, 0));
        await advance(before);
      }
      await first.up();
      await second.up();
      expect(camera.position.length, lessThan(beforePinch));
      record('touch pinch inward');
      await tester.sendEventToBinding(pointer.panZoomStart(point));
      for (var step = 1; step <= 64; step++) {
        final before = frames;
        await tester.sendEventToBinding(
          pointer.panZoomUpdate(point, pan: Offset(0, 400.0 * step)),
        );
        await advance(before);
        if (step % 16 == 0) record('inward $step');
      }
      await tester.sendEventToBinding(pointer.panZoomEnd());
      expect(camera.position.length, lessThan(6378137 + 100000));
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await advance(frames, refine: true);
      record('surface portrait');
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
    debugPrint('Cloud orbit cleanup: $diagnostics');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

class _TileSizedPressure extends ScenePlugin {
  @override
  String get id => 'cloud-orbit-resource-pressure';

  @override
  Future<void> attach(PluginContext context) async {
    final scope = context.createGpuScope(label: '64 MiB tile-sized pressure');
    await scope.resources.createBuffer(
      BufferDescriptor(size: 64 * 1024 * 1024, usage: {BufferUsage.storage}),
    );
  }
}
