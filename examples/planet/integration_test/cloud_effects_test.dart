import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:integration_test/integration_test.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'cloud history, lens and SMAA present and resize without a provider',
    (tester) async {
      final android = defaultTargetPlatform == TargetPlatform.android;
      final scene = Scene()
        ..renderSettings = RenderSettings(
          hdr: true,
          toneMapping: ToneMapping.agx,
        );
      final camera = PerspectiveCamera(
        position: const Vec3(6360100, 0, 0),
        target: const Vec3(6360100, 0, 1000),
        near: 1,
        far: 1e7,
      );
      final clouds = CloudPlugin(
        quality: CloudQualityPreset.high,
        maxResolution: 64,
        shadowMapSize: 16,
        parameters: CloudParameters(localWeatherVelocity: (.001, 0)),
      );
      final effects = ScreenEffectsPlugin(
        settings: ScreenEffectsSettings(
          lens: LensFlareSettings(maxResolution: 64),
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
      controller.use(
        AtmospherePlugin(
          date: DateTime.utc(2026, 3, 20, 12),
          parameters: AtmosphereParameters.legacy(),
          correctAltitude: false,
          maxStarResolution: 32,
        ),
      );
      controller.use(clouds);
      controller.use(effects);
      var frames = 0;
      final subscription = controller.frameStats.listen((frame) {
        expectSync(frame.readbackBytes, 0);
        frames++;
      });
      Future<void> mount(Size size) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox.fromSize(
                size: size,
                child: SceneView(controller: controller, resolutionScale: .25),
              ),
            ),
          ),
        ),
      );
      Future<void> settle(int before) async {
        for (var attempt = 0; attempt < 1500; attempt++) {
          controller.invalidate();
          await tester.pump(const Duration(milliseconds: 25));
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 10)),
          );
          if (controller.status.value case SceneFailed(:final issue)) {
            fail('${issue.code}: ${issue.message}; ${issue.cause}');
          }
        if (frames > before + 2 &&
            clouds.controller.history.accumulatedFrames >= 16) {
          return;
        }
        }
        fail('Cloud effects did not advance native history.');
      }

      try {
        await mount(const Size(320, 240));
        await settle(frames);
        expect(scene.effects, hasLength(30));
        for (final (mode, size) in [
          (CloudTemporalMode.antialias, const Size(240, 320)),
          (CloudTemporalMode.upscale, const Size(384, 256)),
        ]) {
          await clouds.controller.setTemporal(
            CloudTemporalSettings(mode: mode),
          );
          await mount(size);
          await settle(frames);
          expect(clouds.controller.history.valid, isTrue);
          expect(clouds.controller.temporal.mode, mode);
          expect(effects.controller.width, greaterThan(0));
          expect(effects.controller.height, greaterThan(0));
          expect(scene.effects, hasLength(30));
          debugPrint(
            '${mode.name}: $frames native frame samples, '
            '${clouds.controller.history.accumulatedFrames} history frames, '
            '${effects.controller.width}x${effects.controller.height}.',
          );
        }
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        await controller.whenDisposed;
        await subscription.cancel();
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
      debugPrint('Cloud effects cleanup: $diagnostics');
    },
  );
}
