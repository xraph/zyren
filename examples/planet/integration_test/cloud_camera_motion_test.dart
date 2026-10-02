import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:planet/geospatial_scene.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('dense globe navigation retains native cloud history', (
    tester,
  ) async {
    final camera = PerspectiveCamera(
      position: const Vec3(6379137, 0, 0),
      target: const Vec3(6379137, 0, 1000),
      up: const Vec3(1, 0, 0),
      near: 1,
      far: 1e8,
      depthStrategy: DepthStrategy.reversed,
    );
    final scene = Scene()
      ..renderSettings = RenderSettings(hdr: true, toneMapping: ToneMapping.agx)
      ..add(
        Mesh(
          EllipsoidGeometry(longitudeSegments: 384, latitudeSegments: 192),
          StandardMaterial(baseColor: const Color3(.04, .12, .18)),
        ),
      );
    final controls = GlobeControlsPlugin(
      configureGlobe: (value) => value.adjustHeight = true,
    );
    final clouds = CloudPlugin(
      quality: CloudQualityPreset.high,
      maxResolution: 640,
      shadowMapSize: 128,
      parameters: CloudParameters(localWeatherVelocity: (.001, 0)),
    );
    final controller =
        SceneController(
            scene: scene,
            camera: camera,
            runtime: const SceneRuntime.nativeMetal(),
            options: const EngineOptions(
              presentation: PresentationPolicy.requireNative,
            ),
          )
          ..use(GeospatialPlugin())
          ..use(controls)
          ..use(
            AtmospherePlugin(
              date: DateTime.utc(2026, 3, 20, 12),
              parameters: AtmosphereParameters.legacy(),
              maxStarResolution: 32,
            ),
          )
          ..use(clouds);
    var frames = 0, moving = false;
    final records = <Map<String, Object?>>[];
    final intervals = <double>[];
    final subscription = controller.presentations.listen((sample) {
      frames++;
      expectSync(sample.frame.readbackBytes, 0);
      expectSync(sample.frame.presentationPath, PresentationPath.nativeView);
      if (moving) {
        if (sample.interval case final interval?) {
          intervals.add(interval.inMicroseconds / 1000);
        }
        records.add({
          'frame': sample.frame.frameId,
          'history': clouds.controller.history.accumulatedFrames,
          'reason': clouds.controller.history.reason.name,
          'near': camera.near,
          'far': camera.far,
          'uploadedBytes': sample.frame.uploadedBytes,
        });
      }
    });
    final motion = controller.onUpdate((_) {
      if (!moving) return;
      camera.position += const Vec3(1, 0, 0);
      camera.target += const Vec3(1, 0, 0);
    });
    Future<void> until(bool Function() ready) async {
      for (var attempt = 0; attempt < 2400; attempt++) {
        await tester.pump(const Duration(milliseconds: 16));
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 3)),
        );
        if (controller.status.value case SceneFailed(:final issue)) {
          fail('${issue.code}: ${issue.message}');
        }
        if (ready()) return;
      }
      fail('Native camera motion did not finish.');
    }

    try {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LayoutBuilder(
              builder: (context, size) {
                final ratio = MediaQuery.devicePixelRatioOf(context);
                return SceneView(
                  controller: controller,
                  resolutionScale: geospatialResolutionScale(
                    width: size.maxWidth * ratio,
                    height: size.maxHeight * ratio,
                  ),
                );
              },
            ),
          ),
        ),
      );
      await until(
        () => frames > 0 && clouds.controller.history.accumulatedFrames >= 20,
      );
      final initialNear = camera.near;
      moving = true;
      await until(() => records.length >= 48);
      moving = false;
      expect(camera.near, greaterThan(initialNear));
      expect(records.map((r) => r['reason']), everyElement('none'));
      for (var i = 1; i < records.length; i++) {
        expect(records[i]['history'], (records[i - 1]['history'] as int) + 1);
      }
      expect(records.map((r) => r['uploadedBytes']), everyElement(0));
      intervals.sort();
      final beforeResize = frames;
      await tester.binding.setSurfaceSize(const Size(390, 700));
      await until(
        () =>
            frames > beforeResize + 20 &&
            clouds.controller.history.accumulatedFrames >= 16,
      );
      binding.reportData = {
        'suite': 'dense-globe-cloud-camera-motion',
        'passed': true,
        'providerTiles': false,
        'proceduralClouds': true,
        'includesTestHarnessPumping': true,
        'movingFrames': records.length,
        'medianPresentationMs': intervals[intervals.length ~/ 2],
        'p95PresentationMs':
            intervals[math.min(
              intervals.length - 1,
              (intervals.length * .95).floor(),
            )],
        'samples': records,
      };
      debugPrint('Cloud camera motion: ${binding.reportData}');
    } finally {
      moving = false;
      motion.dispose();
      await tester.pumpWidget(const SizedBox());
      controller.dispose();
      await controller.whenDisposed;
      await subscription.cancel();
    }
    final diagnostics = await const MethodChannel(
      'zyren/scene-views',
    ).invokeMapMethod<Object?, Object?>('diagnostics');
    for (final name in [
      'sessions',
      'renderers',
      'retiring',
      'readbackBytes',
      'heldDrawables',
    ]) {
      expect(diagnostics![name], 0, reason: name);
    }
    debugPrint('Cloud camera cleanup: $diagnostics');
  });
}
